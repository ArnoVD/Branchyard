import Foundation

/// High-level git operations on one working tree.
public struct Repository: Sendable, Hashable {
    public let url: URL
    var git: Git { Git(directory: url) }

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public var name: String { url.lastPathComponent }

    // MARK: discovery

    /// The repository root containing `url`, or nil if it isn't inside a git work tree.
    public static func root(containing url: URL) async -> URL? {
        // `rev-parse --show-toplevel` fails inside the .git folder itself.
        let start = url.lastPathComponent == ".git" ? url.deletingLastPathComponent() : url
        guard let result = try? await Git(directory: start).run(["rev-parse", "--show-toplevel"], allowFailure: true),
              result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Finds repositories under `folder` (not descending into repos or dependency folders).
    public static func scan(folder: URL, maxDepth: Int = 4) -> [URL] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", "vendor", "Pods", ".build", "build", "dist", "Library"]
        var found: [URL] = []

        func visit(_ dir: URL, depth: Int) {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                found.append(dir)
                return
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { return }
            for child in children where !skip.contains(child.lastPathComponent) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(folder, depth: 0)
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// `git clone <remoteURL>` into `parent/<name>`. Returns the new repository folder.
    public static func clone(remoteURL: String, into parent: URL, folderName: String) async throws -> URL {
        let destination = parent.appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw GitError(command: "clone", output: "\(destination.path) already exists.")
        }
        try await Git(directory: parent).run(["clone", "--", remoteURL, destination.path])
        return destination
    }

    /// New empty repository in `folder` (created if missing), on branch `main`.
    public static func create(at folder: URL) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            throw GitError(command: "init", output: "\(folder.path) is already a git repository.")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Git(directory: folder).run(["init", "-b", "main"])
        return folder
    }

    /// "git@bitbucket.org:team/my-repo.git" → "my-repo"
    public static func folderName(forRemote remote: String) -> String {
        var last = remote.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repository"
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.isEmpty ? "repository" : last
    }

    // MARK: reading state

    public func status() async throws -> RepoStatus {
        let r = try await git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        return Parsers.status(r.stdout)
    }

    public func branches() async throws -> [Branch] {
        let r = try await git.run(["for-each-ref", "--format=\(Parsers.branchFormat)", "refs/heads", "refs/remotes"])
        return Parsers.branches(r.stdout)
    }

    public func stashes() async throws -> [Stash] {
        let r = try await git.run(["stash", "list", "--format=%gd%x00%s"])
        return Parsers.stashes(r.stdout)
    }

    /// Newest first. Annotated tags are peeled to their commit.
    public func tags() async throws -> [GitTag] {
        let r = try await git.run(["for-each-ref", "--sort=-creatordate",
                                   "--format=%(refname:short)%1f%(objectname)%1f%(*objectname)", "refs/tags"],
                                  allowFailure: true)
        guard r.succeeded else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            return GitTag(name: f[0], sha: f[2].isEmpty ? f[1] : f[2])
        }
    }

    public func remotes() async throws -> [String] {
        try await git.run(["remote"]).stdout.split(separator: "\n").map(String.init)
    }

    public func operationState() async -> OperationState {
        let names = ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD"]
        guard let r = try? await git.run(["rev-parse"] + names.flatMap { ["--git-path", $0] }) else { return .none }
        let paths = r.stdout.split(separator: "\n").map { path -> String in
            let p = String(path)
            return p.hasPrefix("/") ? p : url.appendingPathComponent(p).path
        }
        let exists = paths.map { FileManager.default.fileExists(atPath: $0) }
        guard exists.count == 4 else { return .none }
        if exists[1] || exists[2] { return .rebasing }
        if exists[0] { return .merging }
        if exists[3] { return .cherryPicking }
        return .none
    }

    /// Prepared commit message during a merge (".git/MERGE_MSG"), if any.
    public func mergeMessage() async -> String? {
        guard let r = try? await git.run(["rev-parse", "--git-path", "MERGE_MSG"]) else { return nil }
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = p.hasPrefix("/") ? p : url.appendingPathComponent(p).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Drop git's "# ..." comment lines.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func diff(for change: FileChange) async throws -> [DiffLine] {
        let base = ["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", Repository.fullContext]
        let result: GitResult
        switch (change.area, change.kind) {
        case (.unstaged, .untracked):
            // Exit code 1 just means "there are differences".
            result = try await git.run(base + ["--no-index", "--", "/dev/null", change.path], allowFailure: true)
        case (.staged, _):
            result = try await git.run(base + ["--cached", "-M", "--", change.path] + (change.originalPath.map { [$0] } ?? []))
        default:
            result = try await git.run(base + ["--", change.path])
        }
        return Parsers.diff(result.stdout)
    }

    public func readFile(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: staging & committing

    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git.run(["add", "-A", "--"] + paths)
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let r = try await git.run(["restore", "--staged", "--"] + paths, allowFailure: true)
        if !r.succeeded {
            // No commits yet: there is no HEAD to restore from.
            try await git.run(["rm", "--cached", "-r", "--quiet", "--"] + paths)
        }
    }

    /// Throws away local changes to a file. Untracked files are deleted.
    public func discard(_ change: FileChange) async throws {
        if change.kind == .untracked {
            try await git.run(["clean", "-f", "--", change.path])
        } else {
            try await git.run(["restore", "--", change.path])
        }
    }

    public func commit(message: String) async throws {
        try await git.run(["commit", "-m", message])
    }

    // MARK: remotes

    public func fetch() async throws {
        try await git.run(["fetch", "--all", "--prune"])
    }

    /// Pulls with merge unless the user configured pull.rebase. Conflicts don't throw:
    /// check the returned result and the status afterwards.
    public func pull() async throws -> GitResult {
        let configured = try await git.run(["config", "--get", "pull.rebase"], allowFailure: true)
        let args = configured.succeeded ? ["pull"] : ["pull", "--no-rebase"]
        return try await git.run(args, allowFailure: true)
    }

    /// Pushes the current branch; sets upstream on the first push.
    public func push(currentStatus: RepoStatus) async throws {
        if currentStatus.upstream == nil {
            guard currentStatus.branch != nil else {
                throw GitError(command: "push", output: "HEAD is detached. Create a branch first.")
            }
            let remotes = try await remotes()
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            try await git.run(["push", "-u", remote, "HEAD"])
        } else {
            try await git.run(["push"])
        }
    }

    public func addRemote(name: String, url: String) async throws {
        try await git.run(["remote", "add", name, url])
    }

    /// Pushes the current branch to `remote` and tracks it there.
    public func publish(to remote: String) async throws {
        try await git.run(["push", "-u", remote, "HEAD"])
    }

    // MARK: stash

    public func stash(message: String?) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if let message, !message.isEmpty { args += ["-m", message] }
        try await git.run(args)
    }

    /// Conflicts don't throw (git keeps the stash); check status afterwards.
    public func stashPop(_ ref: String? = nil) async throws -> GitResult {
        try await git.run(["stash", "pop"] + (ref.map { [$0] } ?? []), allowFailure: true)
    }

    public func stashApply(_ ref: String) async throws -> GitResult {
        try await git.run(["stash", "apply", ref], allowFailure: true)
    }

    public func stashDrop(_ ref: String) async throws {
        try await git.run(["stash", "drop", ref])
    }

    // MARK: branches

    public func createBranch(_ name: String, from startPoint: String? = nil) async throws {
        try await git.run(["switch", "-c", name] + (startPoint.map { [$0] } ?? []))
    }

    public func checkout(_ branch: Branch, existingLocal: [Branch]) async throws {
        if branch.isRemote {
            let localName = branch.nameWithoutRemote
            if existingLocal.contains(where: { $0.name == localName }) {
                try await git.run(["switch", localName])
            } else {
                try await git.run(["switch", "--track", branch.name])
            }
        } else {
            try await git.run(["switch", branch.name])
        }
    }

    public func deleteBranch(_ name: String, force: Bool) async throws {
        try await git.run(["branch", force ? "-D" : "-d", name])
    }

    /// Conflicts don't throw; check status afterwards.
    public func merge(_ branchName: String) async throws -> GitResult {
        try await git.run(["merge", "--no-edit", branchName], allowFailure: true)
    }

    // MARK: conflicts

    public func writeResolved(path: String, contents: String) async throws {
        try contents.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await git.run(["add", "--", path])
    }

    public enum Side: String, Sendable { case ours, theirs }

    /// Takes one side for the whole file. Handles "deleted by us/them" conflicts too.
    public func resolveWholeFile(_ change: FileChange, side: Side) async throws {
        let code = change.conflictCode ?? "UU"
        let deletedOnChosenSide = (side == .ours && (code == "DU" || code == "DD"))
            || (side == .theirs && (code == "UD" || code == "DD"))
        if deletedOnChosenSide {
            try await git.run(["rm", "--quiet", "--", change.path])
        } else {
            try await git.run(["checkout", "--\(side.rawValue)", "--", change.path])
            try await git.run(["add", "--", change.path])
        }
    }

    public func abort(_ state: OperationState) async throws {
        switch state {
        case .merging: try await git.run(["merge", "--abort"])
        case .rebasing: try await git.run(["rebase", "--abort"])
        case .cherryPicking: try await git.run(["cherry-pick", "--abort"])
        case .none: break
        }
    }

    /// Continues a rebase / cherry-pick after conflicts are staged. (A merge finishes with a normal commit.)
    public func continueOperation(_ state: OperationState) async throws {
        let noEditor = ["GIT_EDITOR": "true"]
        switch state {
        case .rebasing: try await git.run(["rebase", "--continue"], environment: noEditor)
        case .cherryPicking: try await git.run(["cherry-pick", "--continue"], environment: noEditor)
        case .merging: try await git.run(["commit", "--no-edit"])
        case .none: break
        }
    }
}

// MARK: - Undo support

/// Where HEAD points: a branch, or a detached commit.
public enum HeadRef: Hashable, Sendable {
    case branch(String)
    case detached(String)

    public var label: String {
        switch self {
        case .branch(let name): return name
        case .detached(let sha): return String(sha.prefix(7))
        }
    }
}

extension Repository {
    /// The whole file as context: the app trims it to hunks itself.
    static let fullContext = "-U1000000"

    public func headSHA() async -> String? {
        await sha(of: "HEAD")
    }

    public func sha(of ref: String) async -> String? {
        guard let r = try? await git.run(["rev-parse", "--verify", "-q", "\(ref)^{commit}"], allowFailure: true),
              r.succeeded else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Commits reachable from `to` but not from `from`.
    public func commitCount(from: String, to: String) async -> Int? {
        guard let r = try? await git.run(["rev-list", "--count", "\(from)..\(to)"], allowFailure: true),
              r.succeeded else { return nil }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func headRef() async -> HeadRef? {
        if let r = try? await git.run(["symbolic-ref", "--short", "-q", "HEAD"], allowFailure: true), r.succeeded {
            let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return .branch(name) }
        }
        return await headSHA().map { .detached($0) }
    }

    public func switchTo(_ ref: HeadRef) async throws {
        switch ref {
        case .branch(let name): try await git.run(["switch", name])
        case .detached(let sha): try await git.run(["switch", "--detach", sha])
        }
    }

    /// Moves the current branch to `sha`, keeping the index and working tree.
    public func resetSoft(to sha: String) async throws {
        try await git.run(["reset", "--soft", sha])
    }

    /// Creates `name` at `sha` without switching to it.
    public func createBranch(_ name: String, at sha: String) async throws {
        try await git.run(["branch", name, sha])
    }

    /// The unstaged changes to one tracked file, as a patch `applyPatch` can put back.
    public func worktreePatch(for path: String) async throws -> String {
        try await git.run(["diff", "--binary", "--no-color", "--no-ext-diff", "--", path]).stdout
    }

    public func applyPatch(_ patch: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("branchyard-\(UUID().uuidString).patch")
        try patch.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await git.run(["apply", "--binary", file.path])
    }

    public func writeFile(_ path: String, data: Data) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
}

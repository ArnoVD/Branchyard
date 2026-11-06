import Foundation

/// Cherry-pick, revert and reset from the commit graph.
extension Repository {
    /// How `reset` treats the index and working tree.
    public enum ResetMode: String, CaseIterable, Sendable {
        /// Moves the branch only; changes stay staged.
        case soft
        /// Moves the branch and resets the index; changes stay in the working tree.
        case mixed
        /// Moves the branch and throws away changes to tracked files.
        case hard
        /// Like hard, but refuses instead of overwriting local changes (used by undo).
        case keep
    }

    /// Applies `sha` on top of HEAD as a new commit. Conflicts don't throw; check status
    /// afterwards. `mainline` picks the parent to diff a merge commit against (1 = first parent).
    public func cherryPick(_ sha: String, mainline: Int? = nil) async throws -> GitResult {
        try await git.run(["cherry-pick"] + mainlineArgs(mainline) + [sha], allowFailure: true)
    }

    /// Adds a commit that undoes `sha`. Conflicts don't throw; check status afterwards.
    public func revertCommit(_ sha: String, mainline: Int? = nil) async throws -> GitResult {
        try await git.run(["revert", "--no-edit"] + mainlineArgs(mainline) + [sha], allowFailure: true)
    }

    /// Moves the current branch (or detached HEAD) to `sha`.
    public func reset(to sha: String, mode: ResetMode) async throws {
        try await git.run(["reset", "--\(mode.rawValue)", sha])
    }

    /// Saves the staged and unstaged changes to tracked files as a commit object without
    /// touching anything (`git stash create`). Nil when there is nothing to save.
    public func saveWorkingState() async throws -> String? {
        let sha = try await git.run(["stash", "create"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Puts changes saved by `saveWorkingState` back, staged parts staged again.
    public func restoreWorkingState(_ sha: String) async throws {
        try await git.run(["stash", "apply", "--index", sha])
    }

    /// The fetch URL of `remote`, e.g. "git@github.com:owner/repo.git".
    public func remoteURL(_ remote: String) async -> String? {
        guard let r = try? await git.run(["remote", "get-url", remote], allowFailure: true), r.succeeded else { return nil }
        let url = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    private func mainlineArgs(_ mainline: Int?) -> [String] {
        mainline.map { ["-m", String($0)] } ?? []
    }
}

/// The web page that starts a pull request for a branch, on GitHub or Bitbucket Cloud.
public enum PullRequestLink {
    public enum Host: String, Sendable { case github, bitbucket }

    /// "git@github.com:owner/repo.git" → (.github, "owner/repo"). SSH host aliases such as
    /// "github.com-work" count too. Nil for other hosts.
    public static func parse(remote: String) -> (host: Host, path: String)? {
        var rest = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if let scheme = rest.range(of: "://") {
            // https://user@bitbucket.org/ws/repo.git, ssh://git@github.com:22/owner/repo.git
            rest = String(rest[scheme.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            rest = String(rest[rest.index(after: slash)...])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority.split(separator: ":").first.map(String.init) ?? authority
        } else if let colon = rest.firstIndex(of: ":") {
            // git@github.com:owner/repo.git
            var authority = String(rest[..<colon])
            rest = String(rest[rest.index(after: colon)...])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
        } else {
            return nil
        }
        let kind: Host
        let lower = host.lowercased()
        if lower.hasPrefix("github.com") || lower == "github" || lower.hasPrefix("github-") { kind = .github }
        else if lower.hasPrefix("bitbucket.org") || lower == "bitbucket" || lower.hasPrefix("bitbucket-") { kind = .bitbucket }
        else { return nil }
        var path = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (kind, parts.joined(separator: "/"))
    }

    /// The "new pull request" page for `branch` (its name on the remote), against the
    /// repository's default branch.
    public static func url(remote: String, branch: String) -> URL? {
        guard let (host, path) = parse(remote: remote),
              let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        switch host {
        case .github:
            return URL(string: "https://github.com/\(path)/compare/\(escaped)?expand=1")
        case .bitbucket:
            let query = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? escaped
            return URL(string: "https://bitbucket.org/\(path)/pull-requests/new?source=\(query)&t=1")
        }
    }
}

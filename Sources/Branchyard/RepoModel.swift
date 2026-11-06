import SwiftUI
import AppKit
import GitCore

struct NewBranchRequest: Identifiable {
    let id = UUID()
    let startPoint: String?     // nil = current HEAD
}

/// "Create Tag Here…" on a commit.
struct NewTagRequest: Identifiable {
    let id = UUID()
    let sha: String
    let subject: String
}

/// Rename / Set Upstream sheets for a local branch.
struct BranchRequest: Identifiable {
    enum Kind { case rename, upstream }
    let id = UUID()
    let kind: Kind
    let branch: Branch
}

/// A push the remote rejected because it has commits we don't.
struct ForcePushOffer: Identifiable {
    let id = UUID()
    let status: RepoStatus
    var target: String { status.upstream ?? status.branch ?? "the remote" }
}

extension Repository.PullMode {
    static let storageKey = "pull.mode"
    /// The mode picked in the Pull menu (fast-forward if possible by default).
    static var preferred: Self { UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init) ?? .merge }

    var title: String {
        switch self {
        case .merge: "Fast-forward if possible"
        case .fastForwardOnly: "Fast-forward only"
        case .rebase: "Rebase"
        }
    }
}

/// State and actions for one open repository tab.
@MainActor
final class RepoModel: ObservableObject, Identifiable {
    let repo: Repository
    let id: String
    var name: String { repo.name }

    @Published var status = RepoStatus()
    @Published var branches: [Branch] = []
    @Published var stashes: [Stash] = []
    @Published var tags: [GitTag] = []
    @Published var opState: OperationState = .none
    @Published var loaded = false

    /// The file whose diff is shown (the last one clicked).
    @Published var selectedChangeID: String? {
        didSet {
            if let id = selectedChangeID {
                if !selectedChangeIDs.contains(id) { selectedChangeIDs = [id] }
            } else if !selectedChangeIDs.isEmpty {
                selectedChangeIDs = []
            }
        }
    }
    /// All selected files (⌘-click / ⇧-click), always within one list.
    @Published private(set) var selectedChangeIDs: Set<String> = []
    @Published var diff: [DiffLine] = []
    @Published var conflict: ConflictFile?
    @Published var conflictChoices: [Int: ConflictFile.Resolution] = [:]
    @Published var detailError: String?

    // History graph (middle pane) and the commit picked in it (right pane).
    @Published var graph: [GraphRow] = []
    @Published var graphLanes = 1
    @Published var selectedCommitSHA: String?
    @Published var commitDetail: CommitDetail?
    @Published var selectedCommitFileID: String?
    /// Bumped to ask the graph to scroll to the selected commit.
    @Published var scrollRequest = 0

    @Published var commitMessage = ""
    @Published var busy: String?
    /// The toolbar button whose operation is running (it shows a spinner).
    @Published var busyAction: ToolAction?
    /// Bottom-left notifications after toolbar actions.
    @Published var toasts: [Toast] = []
    /// Set by an operation to replace its toast's default detail line, or the whole toast.
    private var toastTitle: String?
    private var toastDetail: String?
    private var toastOverride: Toast?
    /// The operation reported its outcome another way (e.g. the force push offer): no toast.
    private var skipToast = false
    /// Local commits a push would send: `ahead` with an upstream, else commits no remote has yet.
    @Published var unpushed = 0
    /// Last long-running operation, for the status bar.
    @Published var lastActivity: Activity?
    /// When `git fetch` last ran (FETCH_HEAD's date), by us or anything else.
    @Published var lastFetched: Date?
    @Published private(set) var undoStack: [UndoStep] = []
    @Published private(set) var redoStack: [UndoStep] = []
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var newBranchRequest: NewBranchRequest?
    @Published var newTagRequest: NewTagRequest?
    @Published var branchRequest: BranchRequest?
    @Published var forcePushOffer: ForcePushOffer?
    @Published var remotes: [String] = []
    /// "Amend previous commit": the next commit replaces HEAD instead of adding one.
    @Published var amend = false {
        didSet {
            guard amend, !oldValue else { return }
            Task {
                if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let last = await repo.lastCommitMessage() {
                    commitMessage = last
                }
            }
        }
    }
    /// The "Publish to GitHub" sheet.
    @Published var showPublish = false

    private var detailKey: String?
    private var selectedPath: String?
    private var commits: [Commit] = []
    private var graphHasWIP = false

    init(url: URL) {
        repo = Repository(url: url)
        id = repo.url.path
    }

    // MARK: derived

    var selectedChange: FileChange? { status.allChanges.first { $0.id == selectedChangeID } }
    /// A file's diff (working copy or commit) is open in the middle pane.
    var showsFileDiff: Bool { selectedChangeID != nil || selectedCommitFileID != nil }
    var selectedChanges: [FileChange] { status.allChanges.filter { selectedChangeIDs.contains($0.id) } }

    /// Called by the file lists. Keeps the diff on the file that was just added, if any.
    func setChangeSelection(_ ids: Set<String>) {
        let added = ids.subtracting(selectedChangeIDs)
        selectedChangeIDs = ids
        if let id = added.first {
            if selectedChangeID != id { selectedChangeID = id }
        } else if !(selectedChangeID.map(ids.contains) ?? false) {
            selectedChangeID = ids.first
        }
    }
    var localBranches: [Branch] { branches.filter { !$0.isRemote } }
    var remoteGroups: [(remote: String, branches: [Branch])] {
        Dictionary(grouping: branches.filter(\.isRemote), by: { $0.remoteName ?? "?" })
            .sorted { $0.key < $1.key }
            .map { (remote: $0.key, branches: $0.value) }
    }
    var currentBranchName: String? { status.branch }
    var changeCount: Int { status.allChanges.count }

    var selectedCommitFile: CommitFile? {
        guard let id = selectedCommitFileID else { return nil }
        return commitDetail?.files.first { $0.id == id }
    }
    /// A real commit (not WIP) is picked: the right pane shows its details.
    var showsCommitDetail: Bool {
        selectedChangeID == nil && selectedCommitSHA != nil && selectedCommitSHA != Commit.wipSHA
    }

    var canCommit: Bool {
        busy == nil
            && status.conflicted.isEmpty
            && (!status.staged.isEmpty || opState == .merging || (amend && !commits.isEmpty))
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Amending a commit the remote already has means a force push later.
    var amendRewritesPushed: Bool {
        amend && status.upstream != nil && unpushed == 0 && status.behind == 0
    }

    // MARK: loading

    func refresh() async {
        guard FileManager.default.fileExists(atPath: repo.url.path) else {
            errorMessage = "This folder no longer exists."
            return
        }
        do {
            async let s = repo.status()
            async let b = repo.branches()
            async let st = repo.stashes()
            async let op = repo.operationState()
            async let lg = repo.log()
            async let tg = repo.tags()
            async let rm = repo.remotes()
            let (newStatus, newBranches, newStashes, newOp, newLog, newTags, newRemotes) = try await (s, b, st, op, lg, tg, rm)
            if remotes != newRemotes { remotes = newRemotes }
            if tags != newTags { tags = newTags }
            if status != newStatus { status = newStatus }
            let pending = newStatus.upstream != nil ? newStatus.ahead
                : (newStatus.branch == nil ? 0 : await repo.unpushedCount())
            if unpushed != pending { unpushed = pending }
            if branches != newBranches { branches = newBranches }
            if stashes != newStashes { stashes = newStashes }
            opState = newOp
            let fetched = fetchHeadDate()
            if lastFetched != fetched { lastFetched = fetched }
            updateGraph(newLog)
            loaded = true

            if opState == .merging, commitMessage.isEmpty, let message = await repo.mergeMessage() {
                commitMessage = message
            }
            // A file moves between Unstaged/Staged when you (un)stage it: keep it selected.
            let live = Set(status.allChanges.map(\.id))
            if !selectedChangeIDs.isSubset(of: live) {
                let paths = Set(selectedChangeIDs.map { String($0.drop { $0 != ":" }.dropFirst()) })
                let moved = status.allChanges.filter { paths.contains($0.path) }
                let focus = moved.first { $0.path == selectedPath } ?? moved.first
                // Moved files can land in two lists (partly staged): keep the focused one's list.
                selectedChangeIDs = Set(moved.filter { $0.area == focus?.area }.map(\.id))
                selectedChangeID = focus?.id
            }
            await loadDetail()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateGraph(_ newLog: [Commit]) {
        let wip = !status.isClean
        guard newLog != commits || wip != graphHasWIP || graph.isEmpty && !newLog.isEmpty else { return }
        commits = newLog
        graphHasWIP = wip
        let input = wip ? [Commit.wip(on: status.headOID)] + newLog : newLog
        graph = GraphLayout.rows(for: input)
        graphLanes = max(1, graph.map(\.width).max() ?? 1)
        if let sha = selectedCommitSHA, !graph.contains(where: { $0.commit.sha == sha }) {
            selectCommit(nil)
        }
    }

    // MARK: graph selection

    func selectCommit(_ sha: String?, scroll: Bool = false) {
        selectedChangeID = nil
        selectedCommitFileID = nil
        selectedCommitSHA = sha
        if scroll { scrollRequest += 1 }
        guard let sha, sha != Commit.wipSHA,
              let commit = graph.first(where: { $0.commit.sha == sha })?.commit else {
            commitDetail = nil
            return
        }
        if commitDetail?.commit.sha == sha { return }
        commitDetail = nil
        Task {
            do {
                let detail = try await repo.commitDetail(commit)
                if selectedCommitSHA == sha { commitDetail = detail }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Move the graph selection one row up (-1) or down (+1).
    func moveSelection(_ delta: Int) {
        guard !graph.isEmpty else { return }
        let index = graph.firstIndex { $0.commit.sha == selectedCommitSHA } ?? (delta > 0 ? -1 : graph.count)
        let next = min(max(index + delta, 0), graph.count - 1)
        selectCommit(graph[next].commit.sha, scroll: true)
    }

    /// Select the commit a branch points at.
    func revealInGraph(_ branch: Branch) {
        let row = graph.first { row in
            row.commit.refs.contains { ($0.kind == .local || $0.kind == .remote) && $0.name == branch.name }
        }
        if let row { selectCommit(row.commit.sha, scroll: true) }
    }

    /// Select the commit a tag points at (if it's in the loaded history).
    func revealInGraph(_ tag: GitTag) {
        if graph.contains(where: { $0.commit.sha == tag.sha }) { selectCommit(tag.sha, scroll: true) }
    }

    /// Back from a file diff to the graph.
    func closeDiff() {
        selectedChangeID = nil
        selectedCommitFileID = nil
    }

    func branch(named name: String, remote: Bool) -> Branch? {
        branches.first { $0.isRemote == remote && $0.name == name }
    }

    func copyToPasteboard(_ text: String, what: String = "Text") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(Toast(title: "Copied to Clipboard", detail: what, kind: .info))
    }

    func loadDetail() async {
        if selectedChange == nil, let file = selectedCommitFile, let commit = commitDetail?.commit {
            let key = "commit:\(commit.sha):\(file.path)"
            guard detailKey != key else { return }
            do {
                let lines = try await repo.diff(of: file, in: commit)
                guard selectedCommitFileID == file.id, commitDetail?.commit.sha == commit.sha else { return }
                conflict = nil
                diff = lines
                detailKey = key
                detailError = nil
            } catch {
                detailError = error.localizedDescription
            }
            return
        }
        guard let change = selectedChange else {
            diff = []
            conflict = nil
            detailKey = nil
            return
        }
        selectedPath = change.path
        let key = change.id
        do {
            if change.area == .conflicted {
                let text = (try? repo.readFile(change.path)) ?? ""
                let parsed = ConflictFile(contents: text)
                guard selectedChangeID == key else { return }
                if detailKey != key || conflict?.hunks.count != parsed.hunks.count {
                    conflictChoices = [:]
                }
                conflict = parsed
                diff = []
            } else {
                let lines = try await repo.diff(for: change)
                guard selectedChangeID == key else { return }
                conflict = nil
                diff = lines
            }
            detailKey = key
            detailError = nil
        } catch {
            detailError = error.localizedDescription
        }
    }

    // MARK: running operations

    /// Long-running, one at a time (network ops, commit…). Shows a spinner with `label`
    /// and a toast when it succeeds. `action`: the toolbar button to spin.
    /// `then` runs after a success, once the status is refreshed (commit → push).
    private func run(_ label: String, on action: ToolAction? = nil,
                     then: (@MainActor () -> Void)? = nil,
                     _ operation: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        busyAction = action
        notice = nil
        toastTitle = nil
        toastDetail = nil
        toastOverride = nil
        skipToast = false
        Task {
            var ok = true
            do { try await operation() } catch { ok = false; errorMessage = error.localizedDescription }
            let activity = Activity(label: label, succeeded: ok, date: Date())
            lastActivity = activity
            busy = nil
            busyAction = nil
            // Conflicts show the banner instead.
            if ok, notice == nil, !skipToast {
                showToast(toastOverride ?? Toast(title: toastTitle ?? action?.successTitle ?? activity.text,
                                                 detail: toastDetail))
            }
            await refresh()
            if ok, notice == nil { then?() }
        }
    }

    func showToast(_ toast: Toast) {
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst() }
        Task {
            try? await Task.sleep(for: .seconds(5))
            dismissToast(toast)
        }
    }

    func dismissToast(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
    }

    private func fetchHeadDate() -> Date? {
        let dotGit = repo.url.appendingPathComponent(".git")
        var gitDir = dotGit
        // Worktrees and submodules: .git is a file with "gitdir: <path>".
        if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
            let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: path, relativeTo: repo.url).standardizedFileURL
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: gitDir.appendingPathComponent("FETCH_HEAD").path)
        return attrs?[.modificationDate] as? Date
    }

    /// Like `run`, but the operation returns how to undo it.
    private func runUndoable(_ label: String, on action: ToolAction? = nil,
                             then: (@MainActor () -> Void)? = nil,
                             _ operation: @escaping @MainActor () async throws -> UndoStep?) {
        run(label, on: action, then: then) {
            if let step = try await operation() {
                self.undoStack.append(step)
                if self.undoStack.count > 50 { self.undoStack.removeFirst() }
                self.redoStack = []
            }
        }
    }

    /// After something undo can't reverse (pull, merge, stash…), older steps no longer line up.
    private func forgetUndo() {
        undoStack = []
        redoStack = []
    }

    // MARK: undo / redo

    func undo() {
        guard let step = undoStack.last else { return }
        run("Undoing \(step.title)…", on: .undo) {
            self.toastDetail = "Undid \(step.title)"
            try await self.revert(step)
            self.undoStack.removeLast()
            self.redoStack.append(step)
        }
    }

    func redo() {
        guard let step = redoStack.last else { return }
        run("Redoing \(step.title)…", on: .redo) {
            self.toastDetail = "Redid \(step.title)"
            try await self.reapply(step)
            self.redoStack.removeLast()
            self.undoStack.append(step)
        }
    }

    private func revert(_ step: UndoStep) async throws {
        switch step {
        case .commit(let sha, let parent, let message):
            guard await repo.headSHA() == sha else {
                throw GitError(command: "undo", output: "Can't undo the commit: the branch has moved since.")
            }
            try await repo.resetSoft(to: parent)
            commitMessage = message
        case .checkout(let from, _):
            try await repo.switchTo(from)
        case .createBranch(let name, _, let previous):
            if await repo.headRef() == .branch(name) { try await repo.switchTo(previous) }
            try await repo.deleteBranch(name, force: true)
        case .deleteBranch(let name, let sha):
            try await repo.createBranch(name, at: sha)
        case .discard(let files):
            for file in files {
                if let data = file.data {
                    try repo.writeFile(file.change.path, data: data)
                } else if let patch = file.patch {
                    try await repo.applyPatch(patch)
                }
            }
        }
    }

    private func reapply(_ step: UndoStep) async throws {
        switch step {
        case .commit(let sha, let parent, _):
            guard await repo.headSHA() == parent else {
                throw GitError(command: "redo", output: "Can't redo the commit: the branch has moved since.")
            }
            try await repo.resetSoft(to: sha)
            commitMessage = ""
        case .checkout(_, let to):
            try await repo.switchTo(to)
        case .createBranch(let name, let sha, _):
            try await repo.createBranch(name, at: sha)
            try await repo.switchTo(.branch(name))
        case .deleteBranch(let name, _):
            try await repo.deleteBranch(name, force: true)
        case .discard(let files):
            for file in files { try await repo.discard(file.change) }
        }
    }

    /// Quick local ops (stage/unstage) that may overlap. `done` is the success toast.
    private func quick(_ done: Toast, _ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                showToast(done)
            } catch { errorMessage = error.localizedDescription }
            await refresh()
        }
    }

    /// "a.txt" or "3 files".
    private func describe(_ changes: [FileChange]) -> String {
        changes.count == 1 ? changes[0].fileName : "\(changes.count) files"
    }

    /// For pull / merge / stash pop: conflicts are expected, not an error.
    private func handleMayConflict(_ result: GitResult, what: String) async throws {
        guard !result.succeeded else { return }
        let s = try await repo.status()
        if !s.conflicted.isEmpty {
            let next = await repo.operationState() == .rebasing ? "click Continue" : "commit"
            notice = "\(what) produced \(s.conflicted.count) conflict(s). Resolve them, then \(next)."
            selectedCommitSHA = nil
            selectedChangeID = s.conflicted.first?.id
        } else {
            throw GitError(command: what, output: result.combinedOutput)
        }
    }

    // MARK: remote

    func fetch() {
        run("Fetching…", on: .fetch) {
            try await self.repo.fetch()
            self.toastDetail = "All remotes are up to date"
        }
    }

    /// Fetches quietly in the background (auto-fetch): no spinner, toast or error alert.
    func autoFetch() {
        guard busy == nil, loaded, !remotes.isEmpty else { return }
        Task {
            guard (try? await repo.fetch()) != nil else { return }
            await refresh()
        }
    }

    /// `mode` also becomes the default for the Pull button.
    func pull(mode: Repository.PullMode? = nil) {
        if let mode { UserDefaults.standard.set(mode.rawValue, forKey: Repository.PullMode.storageKey) }
        let mode = mode ?? .preferred
        forgetUndo()
        let branch = status.branch ?? "HEAD"
        let upstream = status.upstream
        run("Pulling…", on: .pull) {
            let before = await self.repo.headSHA()
            let result = try await self.repo.pull(mode: mode)
            try await self.handleMayConflict(result, what: "Pull")
            let after = await self.repo.headSHA()
            let from = upstream.map { " from \($0)" } ?? ""
            if before == after {
                self.toastOverride = Toast(
                    title: "Already Up-to-Date",
                    detail: "No merge necessary. Branch \(upstream ?? branch) was not moved.",
                    kind: .info)
            } else if let before, let after, let n = await self.repo.commitCount(from: before, to: after) {
                self.toastDetail = "\(n) new commit\(n == 1 ? "" : "s") on \(branch)\(from)"
            } else {
                self.toastDetail = "\(branch) updated\(from)"
            }
        }
    }

    func push() {
        let current = status
        // Nowhere to push yet: offer to create the repository on GitHub.
        if current.upstream == nil {
            Task {
                if let remotes = try? await self.repo.remotes(), remotes.isEmpty {
                    self.showPublish = true
                } else {
                    self.pushNow(current)
                }
            }
            return
        }
        pushNow(current)
    }

    /// Creates `name` on the active profile's GitHub account, adds it as a remote and pushes.
    func publishToGitHub(name: String, description: String, isPrivate: Bool) {
        let profile = ProfileStore.shared.effective(forRepo: repo.url.path).profile
        guard let token = ProfileStore.shared.gitHubToken(for: profile.id) else {
            errorMessage = "The profile \(profile.name) has no GitHub account. Connect one in Settings ▸ Profiles."
            return
        }
        let branch = status.branch
        run("Publishing to GitHub…", on: .push) {
            guard let branch else {
                throw GitError(command: "publish", output: "HEAD is detached. Create a branch first.")
            }
            let remotes = try await self.repo.remotes()
            guard let remote = ["origin", "github"].first(where: { !remotes.contains($0) }) else {
                throw GitError(command: "publish", output: "This repository already has remotes named origin and github.")
            }
            let created = try await GitHubClient(token: token).createRepository(
                name: name, description: description, isPrivate: isPrivate)
            try await self.repo.addRemote(name: remote, url: created.cloneURL)
            try await self.repo.publish(to: remote)
            self.toastOverride = Toast(title: "Published to GitHub",
                                       detail: "\(branch) pushed to \(created.fullName)",
                                       link: URL(string: created.htmlURL))
        }
    }

    private func pushNow(_ current: RepoStatus) {
        run("Pushing…", on: .push) {
            do {
                try await self.repo.push(currentStatus: current)
            } catch let error as GitError where Self.isRejected(error.output) {
                self.skipToast = true
                self.forcePushOffer = ForcePushOffer(status: current)
                return
            }
            let branch = current.branch ?? "HEAD"
            if let upstream = current.upstream {
                let n = current.ahead
                self.toastDetail = n > 0
                    ? "\(n) commit\(n == 1 ? "" : "s") pushed to \(upstream)"
                    : "\(branch) was already up to date with \(upstream)"
            } else {
                self.toastDetail = "\(branch) published to the remote"
            }
        }
    }

    private static func isRejected(_ output: String) -> Bool {
        ["[rejected]", "non-fast-forward", "fetch first", "stale info"].contains { output.contains($0) }
    }

    /// Overwrites the remote branch with ours, unless someone pushed since our last fetch.
    func forcePush(_ offer: ForcePushOffer) {
        forcePushOffer = nil
        run("Force pushing…", on: .push) {
            try await self.repo.push(currentStatus: offer.status, force: true)
            self.toastTitle = "Force Pushed"
            self.toastDetail = "\(offer.status.branch ?? "HEAD") replaced \(offer.target)"
        }
    }

    // MARK: staging

    func stage(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        quick(Toast(title: "Staged", detail: describe(changes))) { try await self.repo.stage(changes.map(\.path)) }
    }
    func unstage(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        quick(Toast(title: "Unstaged", detail: describe(changes))) { try await self.repo.unstage(changes.map(\.path)) }
    }
    func stageAll() { stage(status.unstaged) }
    func unstageAll() { unstage(status.staged) }
    func discard(_ changes: [FileChange]) {
        let changes = changes.filter { $0.area == .unstaged }
        guard !changes.isEmpty else { return }
        let label = describe(changes)
        runUndoable("Discarding \(label)…") {
            self.toastTitle = changes.allSatisfy { $0.kind == .untracked } ? "Files Deleted" : "Changes Discarded"
            self.toastDetail = "\(label) · ⌘Z to undo"
            var saved: [DiscardedFile] = []
            for change in changes {
                var data: Data?
                var patch: String?
                if change.kind == .untracked {
                    data = try? Data(contentsOf: self.repo.url.appendingPathComponent(change.path))
                } else {
                    patch = try await self.repo.worktreePatch(for: change.path)
                }
                if data != nil || !(patch ?? "").isEmpty {
                    saved.append(DiscardedFile(change: change, patch: patch, data: data))
                }
            }
            for change in changes { try await self.repo.discard(change) }
            return saved.isEmpty ? nil : .discard(saved)
        }
    }

    func toggleStage(_ change: FileChange) {
        switch change.area {
        case .staged: unstage([change])
        case .unstaged, .conflicted: stage([change])
        }
    }

    /// `andPush`: the "Push after committing" option; pushes once the commit is in.
    func commit(andPush: Bool = false) {
        guard canCommit else { return }
        let message = commitMessage
        let amending = amend
        var pushAfter: (@MainActor () -> Void)?
        if andPush { pushAfter = { self.push() } }
        runUndoable(amending ? "Amending…" : "Committing…", then: pushAfter) {
            // Amend: undo goes back to the commit it replaced.
            let parent = await self.repo.headSHA()
            try await self.repo.commit(message: message, amend: amending)
            self.commitMessage = ""
            self.amend = false
            let subject: String = message.split(separator: "\n").first.map { String($0) } ?? ""
            let head: String? = await self.repo.headSHA()
            self.toastTitle = amending ? "Commit Amended" : "Committed"
            self.toastDetail = head.map { "\($0.prefix(7)) · \(subject)" } ?? subject
            // A first commit has no parent to go back to.
            guard let parent, let sha = head else { return nil }
            return .commit(sha: sha, parent: parent, message: message)
        }
    }

    // MARK: stash

    func stash() {
        forgetUndo()
        let n = status.allChanges.count
        run("Stashing…", on: .stash) {
            try await self.repo.stash(message: nil)
            self.toastDetail = "\(n) changed file\(n == 1 ? "" : "s") put away"
        }
    }

    func pop(_ stash: Stash? = nil) {
        forgetUndo()
        run("Popping stash…", on: stash == nil ? .pop : nil) {
            self.toastTitle = "Stash Popped"
            self.toastDetail = stash?.message
            let result = try await self.repo.stashPop(stash?.ref)
            try await self.handleMayConflict(result, what: "Stash pop")
        }
    }

    func apply(_ stash: Stash) {
        forgetUndo()
        run("Applying stash…") {
            self.toastTitle = "Stash Applied"
            self.toastDetail = stash.message
            let result = try await self.repo.stashApply(stash.ref)
            try await self.handleMayConflict(result, what: "Stash apply")
        }
    }

    func drop(_ stash: Stash) {
        run("Dropping stash…") {
            self.toastTitle = "Stash Dropped"
            self.toastDetail = stash.message
            try await self.repo.stashDrop(stash.ref)
        }
    }

    // MARK: branches

    func createBranch(_ name: String, from startPoint: String?) {
        runUndoable("Creating branch…", on: .branch) {
            self.toastDetail = "Switched to \(name)"
            let previous = await self.repo.headRef()
            try await self.repo.createBranch(name, from: startPoint)
            guard let previous, let sha = await self.repo.headSHA() else { return nil }
            return .createBranch(name: name, sha: sha, previous: previous)
        }
    }

    func checkout(_ branch: Branch) {
        guard !branch.isCurrent else { return }
        runUndoable("Switching to \(branch.nameWithoutRemote)…") {
            self.toastTitle = "Checked Out"
            self.toastDetail = "Switched to \(branch.nameWithoutRemote)"
            let from = await self.repo.headRef()
            try await self.repo.checkout(branch, existingLocal: self.localBranches)
            guard let from, let to = await self.repo.headRef() else { return nil }
            return .checkout(from: from, to: to)
        }
    }

    func deleteBranch(_ branch: Branch, force: Bool) {
        runUndoable("Deleting branch…") {
            self.toastTitle = "Branch Deleted"
            self.toastDetail = "\(branch.name) · ⌘Z to undo"
            let sha = await self.repo.sha(of: "refs/heads/\(branch.name)")
            try await self.repo.deleteBranch(branch.name, force: force)
            return sha.map { .deleteBranch(name: branch.name, sha: $0) }
        }
    }

    func renameBranch(_ branch: Branch, to newName: String) {
        run("Renaming branch…") {
            self.toastTitle = "Branch Renamed"
            self.toastDetail = "\(branch.name) → \(newName)"
            try await self.repo.renameBranch(branch.name, to: newName)
        }
    }

    /// `upstream` like "origin/main"; nil stops tracking.
    func setUpstream(of branch: Branch, to upstream: String?) {
        run("Setting upstream…") {
            self.toastTitle = upstream == nil ? "Upstream Removed" : "Upstream Set"
            self.toastDetail = upstream.map { "\(branch.name) tracks \($0)" } ?? "\(branch.name) no longer tracks a remote branch"
            try await self.repo.setUpstream(of: branch.name, to: upstream)
        }
    }

    /// Pushes any local branch, checked out or not.
    func pushBranch(_ branch: Branch) {
        if branch.isCurrent { push(); return }
        run("Pushing \(branch.name)…", on: .push) {
            try await self.repo.pushBranch(branch)
            if let upstream = branch.upstream, !branch.upstreamGone {
                let n = branch.ahead
                self.toastDetail = n > 0 ? "\(n) commit\(n == 1 ? "" : "s") pushed to \(upstream)"
                    : "\(branch.name) was already up to date with \(upstream)"
            } else {
                self.toastDetail = "\(branch.name) published to the remote"
            }
        }
    }

    // MARK: tags

    /// `pushTo`: also push the new tag to that remote.
    func createTag(_ name: String, at sha: String, message: String?, pushTo remote: String? = nil) {
        run("Creating tag…") {
            self.toastTitle = remote == nil ? "Tag Created" : "Tag Created and Pushed"
            self.toastDetail = "\(name) at \(sha.prefix(7))" + (remote.map { " · pushed to \($0)" } ?? "")
            try await self.repo.createTag(name, at: sha, message: message)
            if let remote { try await self.repo.pushTag(name, to: remote) }
        }
    }

    func deleteTag(_ tag: GitTag) {
        run("Deleting tag…") {
            self.toastTitle = "Tag Deleted"
            self.toastDetail = "\(tag.name) (local)"
            try await self.repo.deleteTag(tag.name)
        }
    }

    func pushTag(_ tag: GitTag, to remote: String) {
        run("Pushing tag…", on: .push) {
            self.toastTitle = "Tag Pushed"
            self.toastDetail = "\(tag.name) to \(remote)"
            try await self.repo.pushTag(tag.name, to: remote)
        }
    }

    func deleteRemoteTag(_ tag: GitTag, from remote: String) {
        run("Deleting tag from \(remote)…") {
            self.toastTitle = "Tag Deleted"
            self.toastDetail = "\(tag.name) removed from \(remote)"
            try await self.repo.deleteRemoteTag(tag.name, from: remote)
        }
    }

    // MARK: .gitignore

    /// `untrack`: committed files to stop tracking (they stay on disk).
    func ignore(_ patterns: [String], untrack: [String] = []) {
        run("Updating .gitignore…") {
            self.toastTitle = untrack.isEmpty ? "Added to .gitignore" : "Untracked and Ignored"
            self.toastDetail = patterns.count == 1 ? patterns[0] : "\(patterns.count) entries"
            try await self.repo.ignore(patterns, untrack: untrack)
        }
    }

    func merge(_ branch: Branch) {
        forgetUndo()
        let target = status.branch ?? "HEAD"
        run("Merging \(branch.name)…") {
            self.toastTitle = "Merged"
            self.toastDetail = "\(branch.name) into \(target)"
            let result = try await self.repo.merge(branch.name)
            try await self.handleMayConflict(result, what: "Merge")
        }
    }

    // MARK: conflicts

    func saveResolution(for change: FileChange) {
        guard let conflict, let text = conflict.resolved(with: conflictChoices) else { return }
        run("Saving resolution…") {
            self.toastTitle = "Resolution Saved"
            self.toastDetail = change.path
            try await self.repo.writeResolved(path: change.path, contents: text)
            self.selectNextConflict(after: change)
        }
    }

    func takeWholeFile(_ change: FileChange, side: Repository.Side) {
        run("Resolving…") {
            self.toastTitle = "Conflict Resolved"
            self.toastDetail = "Used \(side == .ours ? "ours" : "theirs") for \(change.fileName)"
            try await self.repo.resolveWholeFile(change, side: side)
            self.selectNextConflict(after: change)
        }
    }

    /// For conflicts edited by hand in an editor: stage the file as it is now.
    func markResolvedAsIs(_ change: FileChange) {
        run("Marking resolved…") {
            self.toastTitle = "Marked Resolved"
            self.toastDetail = change.path
            try await self.repo.stage([change.path])
            self.selectNextConflict(after: change)
        }
    }

    private func selectNextConflict(after change: FileChange) {
        let next = status.conflicted.first { $0.path != change.path }
        selectedChangeID = next?.id
        conflictChoices = [:]
    }

    func abortOperation() {
        forgetUndo()
        let op = opState
        run("Aborting…") {
            self.toastTitle = "\(op.name) Aborted"
            try await self.repo.abort(op)
        }
    }
    func continueOperation() {
        forgetUndo()
        let op = opState
        run("Continuing…") {
            self.toastTitle = "\(op.name) Continued"
            try await self.repo.continueOperation(op)
        }
    }

    // MARK: Finder / Terminal

    func revealInFinder(_ path: String? = nil) {
        let url = path.map { repo.url.appendingPathComponent($0) } ?? repo.url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInDefaultApp(_ path: String) {
        NSWorkspace.shared.open(repo.url.appendingPathComponent(path))
    }

    func openInTerminal() {
        NSWorkspace.shared.open([repo.url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Toolbar buttons that run a git operation.
private extension OperationState {
    var name: String {
        switch self {
        case .none: "Operation"
        case .merging: "Merge"
        case .rebasing: "Rebase"
        case .cherryPicking: "Cherry-pick"
        }
    }
}

enum ToolAction {
    case undo, redo, fetch, pull, push, branch, stash, pop

    var successTitle: String {
        switch self {
        case .undo: "Undone"
        case .redo: "Redone"
        case .fetch: "Fetched Successfully"
        case .pull: "Pulled Successfully"
        case .push: "Pushed Successfully"
        case .branch: "Branch Created"
        case .stash: "Changes Stashed"
        case .pop: "Stash Popped"
        }
    }
}

/// A notification in the bottom-left corner.
struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, failure }

    let id = UUID()
    let title: String
    var detail: String? = nil
    var kind: Kind = .success
    /// Shown as an "Open" button, e.g. the new GitHub repository.
    var link: URL? = nil
}

/// A finished long-running operation ("Pushing…" → "Pushed").
struct Activity: Equatable {
    let label: String
    let succeeded: Bool
    let date: Date

    var text: String {
        let verb = label.replacingOccurrences(of: "…", with: "")
        guard succeeded else { return "\(verb) failed" }
        let past = [
            ("Fetching", "Fetched"), ("Pulling", "Pulled"), ("Pushing", "Pushed"), ("Committing", "Committed"),
            ("Stashing", "Stashed"), ("Popping", "Popped"), ("Applying", "Applied"), ("Dropping", "Dropped"),
            ("Merging", "Merged"), ("Switching", "Switched"), ("Creating", "Created"), ("Deleting", "Deleted"),
            ("Aborting", "Aborted"), ("Continuing", "Continued"), ("Marking", "Marked"),
            ("Resolving", "Resolved"), ("Saving", "Saved"), ("Discarding", "Discarded"),
            ("Undoing", "Undid"), ("Redoing", "Redid"), ("Amending", "Amended"), ("Renaming", "Renamed"),
            ("Setting", "Set"), ("Updating", "Updated"),
        ]
        for (ing, ed) in past where verb.hasPrefix(ing) { return ed + verb.dropFirst(ing.count) }
        return "\(verb) done"
    }
}

/// One action Undo/Redo can reverse, with what's needed to do it.
enum UndoStep {
    case commit(sha: String, parent: String, message: String)
    case checkout(from: HeadRef, to: HeadRef)
    case createBranch(name: String, sha: String, previous: HeadRef)
    case deleteBranch(name: String, sha: String)
    case discard([DiscardedFile])

    var title: String {
        switch self {
        case .commit(_, _, let message):
            let first = message.split(separator: "\n").first.map(String.init) ?? ""
            return "commit “\(first.count > 40 ? first.prefix(40) + "…" : first)”"
        case .checkout(_, let to): return "checkout \(to.label)"
        case .createBranch(let name, _, _): return "create branch \(name)"
        case .deleteBranch(let name, _): return "delete branch \(name)"
        case .discard(let files):
            return files.count == 1 ? "discard \(files[0].change.fileName)" : "discard \(files.count) files"
        }
    }
}

/// A discarded file and what's needed to bring it back:
/// `patch` for tracked files, `data` for untracked ones.
struct DiscardedFile {
    let change: FileChange
    let patch: String?
    let data: Data?
}

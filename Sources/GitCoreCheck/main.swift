import Foundation
import GitCore

// Exercises GitCore against throwaway repositories in a temp folder.
// Run: swift run GitCoreCheck

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "PASS  \(label)" : "FAIL  \(label)")
    if !condition { failures += 1 }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("branchyard-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

func sh(_ dir: URL, _ args: String...) async throws {
    try await Git(directory: dir).run(Array(args))
}
func write(_ dir: URL, _ path: String, _ text: String) throws {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// A bare "server" repo, plus a clone we work in.
let remote = root.appendingPathComponent("remote.git")
try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
try await sh(remote, "init", "--bare", "-b", "main")

let work = try await Repository.clone(remoteURL: remote.path, into: root, folderName: "work")
let repo = Repository(url: work)
try await sh(work, "config", "user.name", "Check")
try await sh(work, "config", "user.email", "check@example.com")
try await sh(work, "config", "commit.gpgsign", "false")

check(await Repository.root(containing: work.appendingPathComponent(".git")) != nil, "root(containing:) finds repo")
check(Repository.scan(folder: root).map(\.lastPathComponent) == ["work"], "scan finds work tree, skips bare repo")
check(Repository.folderName(forRemote: "git@bitbucket.org:team/my-repo.git") == "my-repo", "folder name from SSH URL")

// First commit + first push sets upstream.
try write(work, "readme.md", "line 1\nline 2\nline 3\n")
try write(work, "dir with space/notes.txt", "hello\n")
var status = try await repo.status()
check(status.headOID == nil && status.unstaged.count == 2, "untracked files before first commit")
try await repo.stage(status.unstaged.map(\.path))
status = try await repo.status()
check(status.staged.count == 2 && status.staged.allSatisfy { $0.kind == .added }, "staged as added")
check(status.staged.contains { $0.path == "dir with space/notes.txt" }, "path with spaces parsed")
try await repo.unstage(["readme.md"])
status = try await repo.status()
check(status.staged.count == 1 && status.unstaged.count == 1, "unstage before first commit")
try await repo.stage(["readme.md"])
try await repo.commit(message: "initial")
status = try await repo.status()
// Cloning an empty repo pre-configures origin/main as upstream even though it doesn't exist yet.
check(status.isClean && status.branch == "main" && status.upstream == "origin/main", "clean after commit")
try await repo.push(currentStatus: status)
status = try await repo.status()
check(status.upstream == "origin/main" && status.ahead == 0, "first push sets upstream")

// Modify, rename, diff.
try write(work, "readme.md", "line 1\nline two\nline 3\n")
try await sh(work, "mv", "dir with space/notes.txt", "notes.txt")
status = try await repo.status()
check(status.staged.contains { $0.kind == .renamed && $0.path == "notes.txt" && $0.originalPath == "dir with space/notes.txt" }, "rename parsed with original path")
let modified = status.unstaged.first { $0.path == "readme.md" }
check(modified?.kind == .modified, "modified file in unstaged")
if let modified {
    let diff = try await repo.diff(for: modified)
    check(diff.contains { $0.kind == .removed && $0.text == "-line 2" && $0.oldNumber == 2 }, "diff removed line with number")
    check(diff.contains { $0.kind == .added && $0.text == "+line two" && $0.newNumber == 2 }, "diff added line with number")
}
try write(work, "new.txt", "brand new\n")
status = try await repo.status()
if let untracked = status.unstaged.first(where: { $0.kind == .untracked }) {
    let diff = try await repo.diff(for: untracked)
    check(diff.contains { $0.text == "+brand new" }, "diff of untracked file")
} else { check(false, "untracked file listed") }

// Stash + pop.
try await repo.stash(message: "wip")
var stashes = try await repo.stashes()
status = try await repo.status()
check(stashes.count == 1 && stashes[0].ref == "stash@{0}" && stashes[0].message.contains("wip"), "stash listed")
check(status.isClean, "clean after stash (incl. untracked)")
_ = try await repo.stashPop()
stashes = try await repo.stashes()
status = try await repo.status()
check(stashes.isEmpty && !status.isClean, "stash pop restores changes")
try await repo.stage(status.allChanges.map(\.path))
try await repo.commit(message: "second")

// Branches: create, ahead tracking, remote branch.
try await repo.createBranch("feature/x")
try write(work, "readme.md", "line 1\nFEATURE\nline 3\n")
try await repo.stage(["readme.md"])
try await repo.commit(message: "feature change")
status = try await repo.status()
try await repo.push(currentStatus: status)
var branches = try await repo.branches()
check(branches.contains { $0.name == "feature/x" && $0.isCurrent && !$0.isRemote }, "new branch is current")
check(branches.contains { $0.name == "origin/feature/x" && $0.isRemote && $0.nameWithoutRemote == "feature/x" && $0.remoteName == "origin" }, "remote branch parsed")
check(!branches.contains { $0.refName.hasSuffix("/HEAD") }, "origin/HEAD skipped")

// Conflict: main changes the same line.
let mainBranch = branches.first { $0.name == "main" }!
try await repo.checkout(mainBranch, existingLocal: branches)
check(try await repo.status().branch == "main", "checkout main")
try write(work, "readme.md", "line 1\nMAIN\nline 3\n")
try await repo.stage(["readme.md"])
try await repo.commit(message: "main change")
branches = try await repo.branches()
check(branches.first { $0.name == "main" }?.ahead == 2, "ahead count on branch (second + main change unpushed)")

_ = try await repo.merge("feature/x")
status = try await repo.status()
let opState = await repo.operationState()
check(opState == .merging, "merge in progress detected")
check(status.conflicted.first?.path == "readme.md" && status.conflicted.first?.conflictCode == "UU", "conflict listed as UU")

let conflict = ConflictFile(contents: try repo.readFile("readme.md"))
check(conflict.hunks.count == 1 && conflict.hunks[0].ours == ["MAIN"] && conflict.hunks[0].theirs == ["FEATURE"], "conflict hunk parsed")
check(conflict.hunks.first?.theirsLabel == "feature/x", "conflict labels parsed")
check(conflict.resolved(with: [:]) == nil, "unresolved returns nil")
let resolvedText = conflict.resolved(with: [0: .oursThenTheirs])
check(resolvedText == "line 1\nMAIN\nFEATURE\nline 3\n", "resolution keeps trailing newline")
try await repo.writeResolved(path: "readme.md", contents: resolvedText!)
status = try await repo.status()
check(status.conflicted.isEmpty && status.staged.contains { $0.path == "readme.md" }, "resolved file staged")
let mergeMsg = await repo.mergeMessage()
check(mergeMsg?.hasPrefix("Merge branch 'feature/x'") == true, "merge message read")
try await repo.commit(message: mergeMsg!)
check(await repo.operationState() == .none, "merge finished")

// Second conflict, abort it, then whole-file "theirs".
try await repo.checkout(branches.first { $0.name == "feature/x" }!, existingLocal: branches)
try write(work, "readme.md", "other\n")
try await repo.stage(["readme.md"]); try await repo.commit(message: "feature again")
try await repo.checkout(branches.first { $0.name == "main" }!, existingLocal: branches)
_ = try await repo.merge("feature/x")
try await repo.abort(.merging)
let afterAbortState = await repo.operationState()
let afterAbortClean = try await repo.status().isClean
check(afterAbortState == .none && afterAbortClean, "merge abort")
_ = try await repo.merge("feature/x")
if let c = try await repo.status().conflicted.first {
    try await repo.resolveWholeFile(c, side: .theirs)
    check(try repo.readFile("readme.md") == "other\n", "take theirs for whole file")
} else { check(false, "second conflict present") }
try await repo.continueOperation(.merging)
check(await repo.operationState() == .none, "continue (commit) finishes merge")

// Pull: second clone pushes, first pulls.
let other = try await Repository.clone(remoteURL: remote.path, into: root, folderName: "other")
try await sh(other, "config", "user.name", "Other"); try await sh(other, "config", "user.email", "o@example.com")
try await sh(other, "switch", "feature/x")
try write(other, "remote.txt", "from other\n")
let otherRepo = Repository(url: other)
try await otherRepo.stage(["remote.txt"]); try await otherRepo.commit(message: "from other")
try await otherRepo.push(currentStatus: try await otherRepo.status())
try await repo.checkout(branches.first { $0.name == "feature/x" }!, existingLocal: branches)
try await repo.fetch()
check(try await repo.status().behind == 1, "fetch shows behind 1")
let pull = try await repo.pull()
check(pull.succeeded && FileManager.default.fileExists(atPath: work.appendingPathComponent("remote.txt").path), "pull fast-forwards")

// Remote-only branch checkout creates a tracking branch.
try await sh(other, "switch", "-c", "only-remote")
try await sh(other, "push", "-u", "origin", "HEAD")
try await repo.fetch()
branches = try await repo.branches()
if let remoteOnly = branches.first(where: { $0.name == "origin/only-remote" }) {
    try await repo.checkout(remoteOnly, existingLocal: branches.filter { !$0.isRemote })
    let s = try await repo.status()
    check(s.branch == "only-remote" && s.upstream == "origin/only-remote", "checkout remote branch tracks it")
} else { check(false, "remote-only branch visible after fetch") }

// Discard.
try write(work, "remote.txt", "changed\n")
try write(work, "junk.txt", "junk\n")
for change in try await repo.status().unstaged { try await repo.discard(change) }
check(try await repo.status().isClean, "discard tracked + untracked")

// History + graph.
let history = try await repo.log()
check(history.count >= 6, "log lists commits (\(history.count))")
check(history.contains { $0.isMerge && $0.subject.hasPrefix("Merge branch 'feature/x'") }, "merge commit has two parents")
check(history.first?.refs.contains { $0.isHead && $0.kind == .local } == true || history.contains { $0.refs.contains { $0.isHead } }, "HEAD ref decorated")
check(history.contains { $0.refs.contains { $0.kind == .remote && $0.name == "origin/feature/x" } }, "remote ref decorated")
check(!history.contains { $0.refs.contains { $0.name.hasSuffix("/HEAD") } }, "origin/HEAD not shown as ref")
let rows = GraphLayout.rows(for: history)
check(rows.count == history.count, "one graph row per commit")
check(rows.contains { $0.lane > 0 }, "branches get their own lane")
let mergeRow = rows.first { $0.commit.isMerge }!
check(mergeRow.segments.filter { !$0.upper && $0.fromLane == mergeRow.lane }.count == 2, "merge row draws two parent lines")
check(rows.last!.segments.allSatisfy { $0.upper }, "root commit has no lines below")
/// Every line leaving a row at the bottom continues into the next row at the top.
func graphIsConnected(_ rows: [GraphRow]) -> Bool {
    zip(rows, rows.dropFirst()).allSatisfy { row, next in
        Set(row.segments.filter { !$0.upper }.map(\.toLane)) == Set(next.segments.filter(\.upper).map(\.fromLane))
    }
}
check(graphIsConnected(rows), "graph lines connect row to row")
// A merge whose second parent is already on another lane: that lane keeps going through the merge row.
func fake(_ sha: String, _ parents: [String]) -> Commit {
    Commit(sha: sha, parents: parents, author: "a", email: "e", date: Date(), subject: sha, refs: [])
}
let joinRows = GraphLayout.rows(for: [fake("A", ["C"]), fake("B", ["D", "C"]), fake("D", ["C"]), fake("C", [])])
check(graphIsConnected(joinRows), "lane stays connected when a merge parent joins it")
check(joinRows[1].segments.contains { !$0.upper && $0.fromLane == 0 && $0.toLane == 0 }, "joined lane passes straight through")
let wipRows = GraphLayout.rows(for: [Commit.wip(on: history[0].sha)] + history)
check(wipRows[0].commit.isWIP && wipRows[1].lane == wipRows[0].lane, "WIP sits on HEAD's lane")
let featureMerge = history.first { $0.isMerge && $0.subject == "Merge branch 'feature/x'" }!
let mergeDetail = try await repo.commitDetail(featureMerge)
check(mergeDetail.files.contains { $0.path == "readme.md" }, "merge commit files vs first parent")
let rootCommit = history.last!
let rootDetail = try await repo.commitDetail(rootCommit)
check(!rootDetail.files.isEmpty && rootDetail.files.allSatisfy { $0.kind == .added }, "root commit files listed as added")
let rootDiff = try await repo.diff(of: rootDetail.files[0], in: rootCommit)
check(rootDiff.contains { $0.kind == .added }, "root commit file diff")
let renameCommit = history.first { $0.subject == "rename" }
if let renameCommit {
    let d = try await repo.commitDetail(renameCommit)
    check(d.files.contains { $0.kind == .renamed && $0.originalPath != nil }, "rename in commit files")
}
check(Parsers.refs("HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0").map(\.name) == ["main", "origin/main", "v1.0"], "ref decoration parsed")

// Profile identity: author override and GitHub header reach git, then clear again.
GitIdentity.environment = GitIdentity.environment(authorName: "Profile Person", authorEmail: "me@example.com", gitHubToken: "tok")
try "profile\n".write(to: work.appendingPathComponent("profile.txt"), atomically: true, encoding: .utf8)
try await repo.stage(["profile.txt"])
try await repo.commit(message: "as profile")
let profileAuthor = try await Git(directory: work).run(["log", "-1", "--format=%an <%ae>|%cn <%ce>", "HEAD"]).stdout
check(profileAuthor.trimmingCharacters(in: .whitespacesAndNewlines) == "Profile Person <me@example.com>|Profile Person <me@example.com>", "profile author applied to commit (\(profileAuthor.trimmingCharacters(in: .newlines)))")
let header = try await Git(directory: work).run(["config", "--get", "http.https://github.com/.extraheader"]).stdout
check(header.hasPrefix("Authorization: Basic "), "GitHub auth header visible to git")
// Folder rule beats the active profile.
GitIdentity.rules = [GitIdentity.FolderRule(folder: root.path, environment: GitIdentity.environment(
    authorName: "Work Person", authorEmail: "work@example.com", gitHubToken: nil))]
try "rule\n".write(to: work.appendingPathComponent("profile.txt"), atomically: true, encoding: .utf8)
try await repo.stage(["profile.txt"])
try await repo.commit(message: "as folder rule")
let ruleAuthor = try await Git(directory: work).run(["log", "-1", "--format=%an <%ae>", "HEAD"]).stdout
check(ruleAuthor.trimmingCharacters(in: .whitespacesAndNewlines) == "Work Person <work@example.com>", "folder rule overrides active profile")
check(GitIdentity.matchingFolder("/a/b/c", in: ["/a", "/a/b", "/a/bc"]) == 1, "deepest folder rule wins")
check(GitIdentity.matchingFolder("/a/bc", in: ["/a/b"]) == nil, "folder rule needs a path boundary")
GitIdentity.rules = []
GitIdentity.environment = [:]
let plain = try await Git(directory: work).run(["config", "--get", "http.https://github.com/.extraheader"], allowFailure: true)
check(!plain.succeeded, "no header without a profile token")

// MARK: quick wins: amend, pull modes, force push, tags, branch housekeeping, ignore
let qwRemote = root.appendingPathComponent("qw.git")
try FileManager.default.createDirectory(at: qwRemote, withIntermediateDirectories: true)
try await sh(qwRemote, "init", "--bare", "-b", "main")
func qwClone(_ name: String) async throws -> Repository {
    let dir = try await Repository.clone(remoteURL: qwRemote.path, into: root, folderName: name)
    try await sh(dir, "config", "user.name", "Check")
    try await sh(dir, "config", "user.email", "check@example.com")
    try await sh(dir, "config", "commit.gpgsign", "false")
    return Repository(url: dir)
}
func out(_ r: Repository, _ args: String...) async throws -> String {
    try await Git(directory: r.url).run(Array(args)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}
let qa = try await qwClone("qa")
try write(qa.url, "a.txt", "one\n")
try await qa.stage(["a.txt"])
try await qa.commit(message: "first")
try await qa.push(currentStatus: try await qa.status())

// Amend: message only, then with a staged file. Still one commit on top.
try write(qa.url, "b.txt", "bee\n")
try await qa.stage(["b.txt"])
try await qa.commit(message: "second")
check(await qa.lastCommitMessage() == "second", "last commit message")
try await qa.commit(message: "second, reworded", amend: true)
check(try await out(qa, "rev-list", "--count", "HEAD") == "2", "amend keeps commit count")
check(await qa.lastCommitMessage() == "second, reworded", "amend rewrites message")
try write(qa.url, "c.txt", "sea\n")
try await qa.stage(["c.txt"])
try await qa.commit(message: "second + c", amend: true)
check(try await out(qa, "show", "--name-only", "--format=", "HEAD").contains("c.txt"), "amend adds staged file")
try await qa.push(currentStatus: try await qa.status())

// Force push: amend a pushed commit → plain push rejected, force-with-lease goes through.
try await qa.commit(message: "second, amended after push", amend: true)
var rejection = ""
do { try await qa.push(currentStatus: try await qa.status()) } catch let e as GitError { rejection = e.output }
check(rejection.contains("rejected") || rejection.contains("non-fast-forward"), "push of rewritten commit rejected")
try await qa.push(currentStatus: try await qa.status(), force: true)
check(try await out(qa, "rev-parse", "HEAD") == (try await out(qa, "ls-remote", "origin", "refs/heads/main")).prefix(40).description,
      "force push replaced remote branch")

// Pull modes on diverged branches.
let qb = try await qwClone("qb")
func diverge(_ tag: String) async throws {
    try write(qa.url, "a-\(tag).txt", "a\n"); try await qa.stage(["a-\(tag).txt"]); try await qa.commit(message: "a \(tag)")
    try await qa.push(currentStatus: try await qa.status())
    try write(qb.url, "b-\(tag).txt", "b\n"); try await qb.stage(["b-\(tag).txt"]); try await qb.commit(message: "b \(tag)")
}
try await diverge("1")
let ffOnly = try await qb.pull(mode: .fastForwardOnly)
check(!ffOnly.succeeded, "fast-forward-only pull refuses diverged branches")
let rebased = try await qb.pull(mode: .rebase)
let mergesAfterRebase = try await out(qb, "rev-list", "--merges", "--count", "HEAD")
check(rebased.succeeded && mergesAfterRebase == "0", "rebase pull stays linear")
check(try await out(qb, "log", "-1", "--format=%s") == "b 1", "rebase pull replays local commit on top")
try await qb.push(currentStatus: try await qb.status())
_ = try await qa.pull(mode: .fastForwardOnly)
try await diverge("2")
let merged = try await qb.pull(mode: .merge)
let mergesAfterMerge = try await out(qb, "rev-list", "--merges", "--count", "HEAD")
check(merged.succeeded && mergesAfterMerge == "1", "merge pull makes a merge commit")
try await sh(qb.url, "reset", "--hard", "origin/main")
let ffPull = try await qb.pull(mode: .merge)
check(ffPull.succeeded, "pull when already up to date")

// Tags: lightweight + annotated, push, delete remote, delete local.
let head = try await out(qb, "rev-parse", "HEAD")
try await qb.createTag("v1.0", at: head, message: nil)
try await qb.createTag("v1.1", at: "HEAD~1", message: "Release 1.1")
let qbTags = try await qb.tags()
check(qbTags.contains { $0.name == "v1.0" && $0.sha == head } && qbTags.contains { $0.name == "v1.1" }, "tags created")
check(try await out(qb, "cat-file", "-t", "v1.1") == "tag", "tag with message is annotated")
try await qb.pushTag("v1.1", to: "origin")
check(try await out(qb, "ls-remote", "--tags", "origin").contains("refs/tags/v1.1"), "tag pushed")
try await qb.deleteRemoteTag("v1.1", from: "origin")
check(!(try await out(qb, "ls-remote", "--tags", "origin").contains("refs/tags/v1.1")), "remote tag deleted")
try await qb.deleteTag("v1.0")
check(!(try await qb.tags().contains { $0.name == "v1.0" }), "local tag deleted")

// Branch housekeeping: push a branch you're not on, rename it, set/unset upstream.
try await sh(qb.url, "branch", "topic")
var topic = try await qb.branches().first { $0.name == "topic" }!
try await qb.pushBranch(topic)
topic = try await qb.branches().first { $0.name == "topic" }!
let qbBranch = try await qb.status().branch
check(topic.upstream == "origin/topic" && qbBranch == "main", "push of other branch sets its upstream, HEAD stays")
try await qb.renameBranch("topic", to: "topic-2")
let renamed = try await qb.branches().first { $0.name == "topic-2" }
check(renamed?.upstream == "origin/topic", "rename keeps upstream")
try await qb.setUpstream(of: "topic-2", to: nil)
check(try await qb.branches().first { $0.name == "topic-2" }?.upstream == nil, "upstream unset")
try await qb.setUpstream(of: "topic-2", to: "origin/main")
check(try await qb.branches().first { $0.name == "topic-2" }?.upstream == "origin/main", "upstream set")
try await sh(qb.url, "branch", "--set-upstream-to=origin/topic", "topic-2")
try await sh(qb.url, "switch", "topic-2")
try write(qb.url, "t.txt", "t\n"); try await qb.stage(["t.txt"]); try await qb.commit(message: "topic work")
try await sh(qb.url, "switch", "main")
try await qb.pushBranch(try await qb.branches().first { $0.name == "topic-2" }!)
check(try await out(qb, "rev-parse", "topic-2") == (try await out(qb, "ls-remote", "origin", "refs/heads/topic")).prefix(40).description,
      "push of non-current branch to its upstream")

// Ignore: untracked file, extension, tracked file (untracked but kept on disk), no duplicates.
try write(qb.url, "debug.log", "x\n")
try write(qb.url, "build/out.bin", "x\n")
try await qb.ignore(["*.log"])
try await qb.ignore(["/build/", "*.log"])
var qs = try await qb.status()
check(!qs.allChanges.contains { $0.path == "debug.log" || $0.path.hasPrefix("build") }, "ignored files leave the list")
let gitignore = try String(contentsOf: qb.url.appendingPathComponent(".gitignore"), encoding: .utf8)
check(gitignore == "*.log\n/build/\n", "ignore rules added once (\(gitignore.debugDescription))")
try await qb.ignore(["/a.txt"], untrack: ["a.txt"])
qs = try await qb.status()
check(qs.staged.contains { $0.path == "a.txt" && $0.kind == .deleted }
      && FileManager.default.fileExists(atPath: qb.url.appendingPathComponent("a.txt").path), "stop tracking keeps file on disk")
try await qb.ignore(["/nothing-tracked/"], untrack: ["nothing-tracked"])
check(true, "untracking a folder with no tracked files is fine")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)

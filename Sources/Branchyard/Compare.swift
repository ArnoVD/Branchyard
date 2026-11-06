import Foundation
import AppKit
import GitCore

/// One side of a comparison: a revision, or the working copy when `rev` is nil.
struct CompareSide: Equatable {
    let rev: String?
    let title: String
    var detail: String? = nil

    static let workingCopy = CompareSide(rev: nil, title: "Working Copy")

    static func commit(_ commit: Commit) -> CompareSide {
        CompareSide(rev: commit.sha, title: commit.shortSHA, detail: commit.subject)
    }

    static func branch(_ branch: Branch) -> CompareSide {
        CompareSide(rev: branch.refName, title: branch.name)
    }

    var icon: String {
        guard let rev else { return "pencil" }
        if rev.hasPrefix("refs/remotes/") { return "cloud" }
        return rev.hasPrefix("refs/") ? "arrow.triangle.branch" : "smallcircle.filled.circle"
    }
}

/// What the middle pane compares.
struct CompareRequest: Equatable {
    enum Tab: String, CaseIterable { case files = "Files", commits = "Commits" }

    var base: CompareSide
    var target: CompareSide
    /// Only what `target` changed since it split off from `base` (like a pull request).
    var sinceMergeBase: Bool
    var tab: Tab = .files
}

extension RepoModel {
    /// Shows what changed from `base` to `target` in the middle pane.
    func compare(_ base: CompareSide, _ target: CompareSide, sinceMergeBase: Bool = false) {
        guard base.rev != nil || target.rev != nil else { return }
        // The working copy is always the newer side.
        let (from, to) = base.rev == nil ? (target, base) : (base, target)
        closeSearch()
        selectedChangeID = nil
        selectedCommitFileID = nil
        fileInspector = nil
        comparison = CompareRequest(base: from, target: to, sinceMergeBase: sinceMergeBase)
        comparisonResult = nil
        compareFileID = nil
        compareDiff = []
        reloadComparison()
    }

    func compare(_ branch: Branch) {
        guard let current = branches.first(where: { $0.isCurrent }) else { return }
        compare(.branch(current), .branch(branch), sinceMergeBase: true)
    }

    /// Remembers a commit; another commit's menu then offers "Compare with <it>".
    func markForCompare(_ commit: Commit) {
        compareMark = .commit(commit)
        showToast(Toast(title: "Marked \(commit.shortSHA) for Compare",
                        detail: "Right-click another commit → Compare with \(commit.shortSHA), or ⌘-click it",
                        kind: .info))
    }

    func swapComparison() {
        guard var request = comparison, request.target.rev != nil else { return }
        swap(&request.base, &request.target)
        comparison = request
        reloadComparison()
    }

    func setCompareSinceMergeBase(_ on: Bool) {
        guard var request = comparison, request.sinceMergeBase != on else { return }
        request.sinceMergeBase = on
        comparison = request
        reloadComparison()
    }

    func setCompareTab(_ tab: CompareRequest.Tab) {
        comparison?.tab = tab
    }

    func selectCompareFile(_ id: String?) {
        compareFileID = id
        guard let request = comparison, let baseRev = request.base.rev,
              let file = comparisonResult?.files.first(where: { $0.id == id }) else {
            compareDiff = []
            return
        }
        Task {
            do {
                let lines = try await repo.diff(of: file, from: baseRev, to: request.target.rev,
                                                sinceMergeBase: request.sinceMergeBase)
                if compareFileID == id, comparison == request { compareDiff = lines }
            } catch {
                compareError = error.localizedDescription
            }
        }
    }

    func reloadComparison() {
        guard let request = comparison, let baseRev = request.base.rev else { return }
        compareLoading = true
        Task {
            defer { if comparison == request { compareLoading = false } }
            do {
                let result = try await repo.compare(baseRev, request.target.rev, sinceMergeBase: request.sinceMergeBase)
                guard comparison?.base == request.base, comparison?.target == request.target,
                      comparison?.sinceMergeBase == request.sinceMergeBase else { return }
                comparisonResult = result
                compareError = nil
                let keep = result.files.contains { $0.id == compareFileID } ? compareFileID : result.files.first?.id
                selectCompareFile(keep)
            } catch {
                compareError = error.localizedDescription
            }
        }
    }

    /// ⌘-click in the graph: compare the selected commit with the clicked one.
    func commandClick(_ commit: Commit) {
        let base: CompareSide
        if let mark = compareMark {
            base = mark
        } else if let sha = selectedCommitSHA, sha != commit.sha {
            if sha == Commit.wipSHA {
                base = .workingCopy
            } else if let selected = graph.first(where: { $0.commit.sha == sha })?.commit {
                base = .commit(selected)
            } else {
                return selectCommit(commit.sha)
            }
        } else {
            return selectCommit(commit.sha)
        }
        let target: CompareSide = commit.isWIP ? .workingCopy : .commit(commit)
        guard base != target else { return }
        compareMark = nil
        // Older commit first, so the diff reads forward in time.
        let order = graph.map(\.commit.sha)
        let baseIndex = base.rev.flatMap { rev in order.firstIndex(of: rev) } ?? -1
        let targetIndex = target.rev.flatMap { rev in order.firstIndex(of: rev) } ?? -1
        if baseIndex < targetIndex {
            compare(target, base)
        } else {
            compare(base, target)
        }
    }

    var commandKeyDown: Bool { NSEvent.modifierFlags.contains(.command) }
}

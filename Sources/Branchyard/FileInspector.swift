import Foundation
import GitCore

/// Which file the middle pane inspects, and how.
struct FileInspector: Equatable {
    enum Mode: String, CaseIterable {
        case history = "History"
        case blame = "Blame"
    }

    let path: String
    var mode: Mode
    /// Blame this commit's version of the file instead of the working copy.
    var blameRevision: String?
    /// The file's name in `blameRevision`, when it was renamed since.
    var blamePath: String?

    var fileName: String { (path as NSString).lastPathComponent }
}

extension RepoModel {
    /// Opens File History or Blame for `path`. `commit` preselects that commit in the history
    /// and is the version blamed when the file isn't in the working copy.
    func inspectFile(_ path: String, mode: FileInspector.Mode, at commit: String? = nil, blameAt: String? = nil) {
        closeSearch()
        selectedChangeID = nil
        selectedCommitFileID = nil
        let onDisk = FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(path).path)
        fileInspector = FileInspector(path: path, mode: mode, blameRevision: blameAt ?? (onDisk ? nil : (commit ?? "HEAD")))
        fileRevisions = []
        revisionDiff = []
        blame = nil
        inspectorError = nil
        selectedRevisionSHA = nil
        Task { await loadInspector(focus: blameAt ?? commit) }
    }

    func setInspectorMode(_ mode: FileInspector.Mode) {
        guard var inspector = fileInspector, inspector.mode != mode else { return }
        inspector.mode = mode
        fileInspector = inspector
        Task { await loadInspector(focus: selectedRevisionSHA) }
    }

    /// Blame of the file as it was in `sha`.
    func blame(at sha: String) {
        guard let inspector = fileInspector else { return }
        let path = fileRevisions.first { $0.commit.sha == sha }?.file.path
        fileInspector = FileInspector(path: inspector.path, mode: .blame, blameRevision: sha,
                                      blamePath: path == inspector.path ? nil : path)
        blame = nil
        Task { await loadInspector(focus: sha) }
    }

    /// Back to blaming the working copy.
    func blameWorkingCopy() {
        guard let inspector = fileInspector else { return }
        fileInspector = FileInspector(path: inspector.path, mode: .blame)
        blame = nil
        Task { await loadInspector(focus: nil) }
    }

    /// From a blame line to that commit's change in File History.
    func showRevision(_ sha: String) {
        guard var inspector = fileInspector else { return }
        inspector.mode = .history
        fileInspector = inspector
        Task {
            await loadInspector(focus: sha)
        }
    }

    func selectRevision(_ sha: String?) {
        selectedRevisionSHA = sha
        guard let sha, let revision = fileRevisions.first(where: { $0.commit.sha == sha }) else {
            revisionDiff = []
            return
        }
        Task {
            do {
                let lines = try await repo.diff(of: revision.file, in: revision.commit)
                if selectedRevisionSHA == sha { revisionDiff = lines }
            } catch {
                inspectorError = error.localizedDescription
            }
        }
    }

    /// Closes the inspector and selects `sha` in the graph.
    func showInGraph(_ sha: String) {
        closeDiff()
        if graph.contains(where: { $0.commit.sha == sha }) {
            selectCommit(sha, scroll: true)
        } else {
            showToast(Toast(title: "Not in the Graph", detail: "Commit \(sha.prefix(7)) is older than the loaded history", kind: .info))
        }
    }

    private func loadInspector(focus: String?) async {
        guard let inspector = fileInspector else { return }
        inspectorLoading = true
        defer { if fileInspector == inspector { inspectorLoading = false } }
        do {
            switch inspector.mode {
            case .history:
                if fileRevisions.isEmpty {
                    let revisions = try await repo.fileHistory(inspector.path)
                    guard fileInspector?.path == inspector.path else { return }
                    fileRevisions = revisions
                }
                let pick = fileRevisions.first { $0.commit.sha == focus } ?? fileRevisions.first
                if pick?.commit.sha != selectedRevisionSHA || revisionDiff.isEmpty { selectRevision(pick?.commit.sha) }
            case .blame:
                let result = try await repo.blame(inspector.blamePath ?? inspector.path, at: inspector.blameRevision)
                guard fileInspector == inspector else { return }
                blame = result
            }
            inspectorError = nil
        } catch {
            guard fileInspector == inspector else { return }
            inspectorError = error.localizedDescription
        }
    }
}

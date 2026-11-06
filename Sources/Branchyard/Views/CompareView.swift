import SwiftUI
import GitCore

/// Middle pane: what changed between two commits, branches, or a commit and the working copy.
struct CompareView: View {
    @ObservedObject var model: RepoModel
    let request: CompareRequest

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.compareError {
                ContentUnavailableView("Can't compare", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let result = model.comparisonResult {
                switch request.tab {
                case .files: CompareFilesPane(model: model, request: request, result: result)
                case .commits: CompareCommitsPane(model: model, request: request, result: result)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BackToGraphButton(model: model)
            CompareChip(side: request.base).layoutPriority(1)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            CompareChip(side: request.target).layoutPriority(1)
            Button {
                model.swapComparison()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("Swap sides")
            .disabled(request.target.rev == nil)
            Spacer(minLength: 8)
            if model.compareLoading { ProgressView().controlSize(.small) }
            Toggle("Since split", isOn: Binding(get: { request.sinceMergeBase },
                                                          set: { model.setCompareSinceMergeBase($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("On: only what \(request.target.title) changed since it split off from \(request.base.title), like a pull request.\nOff: every difference between them.")
            Picker("", selection: Binding(get: { request.tab }, set: { model.setCompareTab($0) })) {
                ForEach(CompareRequest.Tab.allCases, id: \.self) { tab in
                    Text(title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.byPanel)
    }

    private func title(_ tab: CompareRequest.Tab) -> String {
        guard let result = model.comparisonResult else { return tab.rawValue }
        switch tab {
        case .files: return "Files \(result.files.count)"
        case .commits: return "Commits \(result.ahead.count + result.behind.count)"
        }
    }
}

private struct CompareChip: View {
    let side: CompareSide

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: side.icon).font(.system(size: 10, weight: .semibold))
            Text(side.title).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .medium, design: side.rev?.hasPrefix("refs/") == false ? .monospaced : .default))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
        .frame(maxWidth: 220)
        .fixedSize(horizontal: false, vertical: true)
        .help(side.detail.map { "\(side.title) – \($0)" } ?? side.title)
    }
}

// MARK: - Files

private struct CompareFilesPane: View {
    @ObservedObject var model: RepoModel
    let request: CompareRequest
    let result: Comparison

    var body: some View {
        if result.files.isEmpty {
            ContentUnavailableView("No differences", systemImage: "equal.circle",
                                   description: Text(request.sinceMergeBase
                                                     ? "\(request.target.title) changed nothing since it split off from \(request.base.title)."
                                                     : "Both sides have the same files."))
        } else {
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.compareFileID }, set: { model.selectCompareFile($0) })) {
                    ForEach(result.files) { file in
                        CommitFileRow(file: file)
                            .tag(file.id)
                            .background(RowMenu { menu(file) })
                    }
                }
                .listStyle(.inset)
                .frame(width: 290)
                Divider()
                if let file = result.files.first(where: { $0.id == model.compareFileID }) {
                    DiffView(lines: model.compareDiff, path: file.path, badge: request.base.title)
                } else {
                    Color.clear
                }
            }
        }
    }

    private func menu(_ file: CommitFile) -> [RowMenuItem] {
        var items: [RowMenuItem] = [
            .action("File History") { model.inspectFile(file.path, mode: .history) },
        ]
        if request.target.rev == nil {
            items.append(.action("Open") { model.openInDefaultApp(file.path) })
        }
        items += [.divider, .action("Copy File Path") { model.copyToPasteboard(file.path, what: "File path") }]
        return items
    }
}

// MARK: - Commits

private struct CompareCommitsPane: View {
    @ObservedObject var model: RepoModel
    let request: CompareRequest
    let result: Comparison
    @ViewState private var selection: String?

    var body: some View {
        if result.ahead.isEmpty && result.behind.isEmpty {
            ContentUnavailableView("Same commits", systemImage: "equal.circle",
                                   description: Text("\(request.base.title) and \(request.target.title) point at the same history."))
        } else {
            List(selection: $selection) {
                section("Only in \(request.target.title)", result.ahead)
                section("Only in \(request.base.title)", result.behind)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ commits: [Commit]) -> some View {
        if !commits.isEmpty {
            Section("\(title) · \(commits.count)") {
                ForEach(commits) { commit in
                    CompareCommitRow(commit: commit)
                        .tag(commit.sha)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.showInGraph(commit.sha) }
                        .simultaneousGesture(TapGesture().onEnded { selection = commit.sha })
                        .background(RowMenu { [
                            .action("Show in Graph") { model.showInGraph(commit.sha) },
                            .divider,
                            .action("Copy Commit SHA") { model.copyToPasteboard(commit.sha, what: "Commit SHA \(commit.shortSHA)") },
                        ] })
                }
            }
        }
    }
}

private struct CompareCommitRow: View {
    let commit: Commit

    var body: some View {
        HStack(spacing: 10) {
            Text(commit.subject).lineLimit(1)
            Spacer(minLength: 8)
            Text(commit.author).lineLimit(1).foregroundStyle(.secondary)
            Text(RelativeDate.text(commit.date)).lineLimit(1).foregroundStyle(.secondary).fixedSize()
            Text(commit.shortSHA).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help("Double-click to show in the graph")
    }
}

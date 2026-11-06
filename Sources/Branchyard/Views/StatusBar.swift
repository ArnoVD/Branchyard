import SwiftUI
import GitCore

/// Thin bar along the bottom of the window.
/// Repo tab: branch + sync state, working-tree changes, last operation, last fetch, path.
/// New Tab: repository count.
struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let model = state.selectedTab {
                RepoStatusItems(model: model)
            } else {
                Item(icon: "folder", text: "\(state.library.count) repositories")
                if state.scanning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Scanning…")
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Branchyard \(Self.version)").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color.byTabBar)
        .overlay(alignment: .top) { Rectangle().fill(Color.byHairline).frame(height: 1) }
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

private struct RepoStatusItems: View {
    @ObservedObject var model: RepoModel

    private var status: RepoStatus { model.status }

    var body: some View {
        // Left: where you are and what's changed.
        branchItem
        syncItem
        changesItem
        if model.opState != .none {
            Item(icon: "exclamationmark.triangle.fill", text: model.opState.label, tint: .orange)
        }

        Spacer(minLength: 8)

        // Right: what happened last.
        activityItem
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let fetched = model.lastFetched {
                Item(icon: "arrow.triangle.2.circlepath", text: "Fetched \(relative(fetched, now: context.date))")
                    .help("Last fetch: \(fetched.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Item(icon: "arrow.triangle.2.circlepath", text: "Never fetched")
            }
        }
        Item(icon: "circle.grid.cross", text: commitCount)
        Button {
            model.revealInFinder()
        } label: {
            Text((model.repo.url.path as NSString).abbreviatingWithTildeInPath)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        // Only as wide as the path; the first thing to shorten when the window is narrow.
        .layoutPriority(-1)
        .help("Reveal in Finder")
    }

    private var branchItem: some View {
        Item(icon: "arrow.triangle.branch", text: status.branch ?? "Detached HEAD",
             tint: status.branch == nil ? .orange : nil, bold: true)
    }

    @ViewBuilder private var syncItem: some View {
        if let upstream = status.upstream {
            HStack(spacing: 6) {
                Text(upstream).foregroundStyle(.tertiary)
                if status.behind == 0 && status.ahead == 0 {
                    Text("up to date").foregroundStyle(.tertiary)
                } else {
                    if status.behind > 0 { Text("↓\(status.behind)").foregroundStyle(Color.byAccent) }
                    if status.ahead > 0 { Text("↑\(status.ahead)").foregroundStyle(Color.byAccent) }
                }
            }
            .help("Tracking \(upstream): \(status.behind) to pull, \(status.ahead) to push")
        } else if status.branch != nil {
            Text("no upstream").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var changesItem: some View {
        if status.isClean {
            Item(icon: "checkmark.circle", text: "Clean", tint: .green)
        } else {
            HStack(spacing: 10) {
                if !status.conflicted.isEmpty {
                    Item(icon: "exclamationmark.triangle", text: "\(status.conflicted.count) conflicts", tint: .orange)
                }
                if !status.unstaged.isEmpty {
                    Item(icon: "pencil", text: "\(status.unstaged.count) unstaged")
                }
                if !status.staged.isEmpty {
                    Item(icon: "tray.full", text: "\(status.staged.count) staged", tint: .green)
                }
            }
        }
    }

    @ViewBuilder private var activityItem: some View {
        if let busy = model.busy {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(busy)
            }
        } else if let activity = model.lastActivity {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Item(icon: activity.succeeded ? "checkmark" : "xmark",
                     text: "\(activity.text) · \(relative(activity.date, now: context.date))",
                     tint: activity.succeeded ? nil : .red)
            }
        }
    }

    private var commitCount: String {
        let n = model.graph.filter { !$0.commit.isWIP }.count
        if n >= 1500 { return "1500+ commits" }
        return n == 1 ? "1 commit" : "\(n) commits"
    }

    private func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 30 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct Item: View {
    let icon: String
    let text: String
    var tint: Color? = nil
    var bold = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).fontWeight(bold ? .semibold : .regular)
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(bold ? .primary : .secondary))
    }
}

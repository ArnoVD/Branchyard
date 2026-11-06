import SwiftUI
import GitCore

/// Colors for graph lanes; a lane keeps its color from top to bottom.
enum LaneColors {
    static let palette: [Color] = [
        Color(red: 0.16, green: 0.73, blue: 0.85),  // cyan
        Color(red: 0.60, green: 0.40, blue: 0.95),  // violet
        Color(red: 0.98, green: 0.55, blue: 0.20),  // orange
        Color(red: 0.93, green: 0.30, blue: 0.55),  // pink
        Color(red: 0.30, green: 0.78, blue: 0.40),  // green
        Color(red: 0.25, green: 0.50, blue: 0.95),  // blue
        Color(red: 0.95, green: 0.78, blue: 0.20),  // yellow
        Color(red: 0.90, green: 0.25, blue: 0.25),  // red
    ]
    static func color(_ index: Int) -> Color {
        let colors = Theme.current.lanes ?? palette
        return colors[index % colors.count]
    }
}

/// Middle pane: every commit on every branch, with the lanes that connect them.
struct CommitGraphView: View {
    @ObservedObject var model: RepoModel
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 28
    static let laneWidth: CGFloat = 16
    static let labelWidth: CGFloat = 190

    private var graphWidth: CGFloat {
        CGFloat(min(model.graphLanes, 10)) * Self.laneWidth + 12
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.graph.isEmpty {
                ContentUnavailableView("No commits yet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(model.loaded ? "Make your first commit on the right." : "Loading history…"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.graph) { row in
                                CommitRowView(model: model, row: row, graphWidth: graphWidth,
                                              isSelected: row.commit.sha == model.selectedCommitSHA)
                                    .id(row.commit.sha)
                            }
                        }
                    }
                    .onChange(of: model.scrollRequest) {
                        if let sha = model.selectedCommitSHA {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(sha) }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onTapGesture { focused = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("BRANCH / TAG").frame(width: Self.labelWidth, alignment: .leading).padding(.leading, 10)
            Text("GRAPH").frame(width: graphWidth, alignment: .leading)
            Text("COMMIT MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
            Text("AUTHOR").frame(width: 104, alignment: .leading)
            Text("DATE").frame(width: 112, alignment: .leading)
            Text("SHA").frame(width: 62, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .background(Color.byPanel)
    }
}

// MARK: - Row

private struct CommitRowView: View {
    @ObservedObject var model: RepoModel
    let row: GraphRow
    let graphWidth: CGFloat
    let isSelected: Bool
    @ViewState private var hovering = false

    private var commit: Commit { row.commit }
    private var laneColor: Color { LaneColors.color(row.color) }
    private var isHead: Bool { commit.sha == model.status.headOID }

    var body: some View {
        HStack(spacing: 0) {
            RefLabels(model: model, refs: commit.refs, color: laneColor)
                .frame(width: CommitGraphView.labelWidth, alignment: .leading)
                .padding(.leading, 6)
                .padding(.trailing, 4)
            GraphCell(row: row, isHead: isHead)
                .frame(width: graphWidth, height: CommitGraphView.rowHeight)
                .clipped()
            message
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            Text(commit.author)
                .frame(width: 104, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(commit.isWIP ? "" : Self.relative(commit.date))
                .frame(width: 112, alignment: .leading)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(commit.isWIP ? "" : commit.date.formatted(date: .abbreviated, time: .shortened))
            Text(commit.isWIP ? "" : commit.shortSHA)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 62, alignment: .leading)
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .frame(height: CommitGraphView.rowHeight)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture { model.selectCommit(commit.sha) }
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var message: some View {
        if commit.isWIP {
            HStack(spacing: 8) {
                Text("// WIP").italic().foregroundStyle(.secondary)
                counts
            }
        } else {
            Text(commit.subject)
                .lineLimit(1)
                .fontWeight(isHead ? .semibold : .regular)
                .foregroundStyle(commit.isMerge ? .secondary : .primary)
                .help(commit.subject)
        }
    }

    private var counts: some View {
        HStack(spacing: 6) {
            let s = model.status
            if !s.conflicted.isEmpty { pill("\(s.conflicted.count)", "exclamationmark.triangle", .orange) }
            if !s.unstaged.isEmpty { pill("\(s.unstaged.count)", "pencil", .blue) }
            if !s.staged.isEmpty { pill("\(s.staged.count)", "checkmark", .green) }
        }
    }

    private func pill(_ text: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            if isSelected {
                laneColor.opacity(0.22)
            } else if hovering {
                Color.secondary.opacity(0.08)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !commit.isWIP {
            Button("Create Branch Here…") { model.newBranchRequest = NewBranchRequest(startPoint: commit.sha) }
            Divider()
            Button("Copy Commit SHA") { model.copyToPasteboard(commit.sha, what: "Commit SHA \(commit.sha.prefix(7))") }
            Button("Copy Commit Message") { model.copyToPasteboard(commit.subject, what: "Commit message") }
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Lanes and node

private struct GraphCell: View {
    let row: GraphRow
    let isHead: Bool

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * CommitGraphView.laneWidth + CommitGraphView.laneWidth / 2 + 6 }

            for segment in row.segments {
                let (y0, y1) = segment.upper ? (0, mid) : (mid, size.height)
                let x0 = x(segment.fromLane), x1 = x(segment.toLane)
                var path = Path()
                path.move(to: CGPoint(x: x0, y: y0))
                if x0 == x1 {
                    path.addLine(to: CGPoint(x: x1, y: y1))
                } else {
                    let c = (y0 + y1) / 2
                    path.addCurve(to: CGPoint(x: x1, y: y1),
                                  control1: CGPoint(x: x0, y: c), control2: CGPoint(x: x1, y: c))
                }
                let dashed = row.commit.isWIP && !segment.upper
                context.stroke(path, with: .color(LaneColors.color(segment.color)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 3] : []))
            }

            let center = CGPoint(x: x(row.lane), y: mid)
            let color = LaneColors.color(row.color)
            if row.commit.isWIP {
                let r: CGFloat = 8
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Color.byPane))
                context.stroke(Path(ellipseIn: rect), with: .color(color),
                               style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            } else if row.commit.isMerge {
                let r: CGFloat = 5
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                             with: .color(color))
            } else {
                let r: CGFloat = 9
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
                if isHead {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(color), lineWidth: 1.5)
                }
                context.draw(Text(row.commit.initials)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white),
                             at: center)
            }
        }
    }
}

// MARK: - Branch / tag labels

/// One label per branch name: "main" with laptop + cloud icons when local and origin match.
private struct RefLabel: Identifiable {
    var name: String
    var local: String?          // local branch name
    var remotes: [String] = []  // origin/main …
    var isTag = false
    var isHead = false
    var id: String { (isTag ? "t:" : "b:") + name }
}

private struct RefLabels: View {
    @ObservedObject var model: RepoModel
    let refs: [CommitRef]
    let color: Color

    private var labels: [RefLabel] {
        var result: [RefLabel] = []
        for ref in refs {
            switch ref.kind {
            case .local:
                if let i = result.firstIndex(where: { !$0.isTag && $0.name == ref.name }) {
                    result[i].local = ref.name
                    result[i].isHead = result[i].isHead || ref.isHead
                } else {
                    result.append(RefLabel(name: ref.name, local: ref.name, isHead: ref.isHead))
                }
            case .remote:
                if let i = result.firstIndex(where: { !$0.isTag && $0.name == ref.branchName }) {
                    result[i].remotes.append(ref.name)
                } else {
                    result.append(RefLabel(name: ref.branchName, remotes: [ref.name]))
                }
            case .tag:
                result.append(RefLabel(name: ref.name, isTag: true))
            case .detachedHead:
                result.append(RefLabel(name: "HEAD", isHead: true))
            }
        }
        // Current branch first, then local branches, then remote-only, then tags.
        return result.sorted { a, b in
            func rank(_ l: RefLabel) -> Int { l.isHead ? 0 : l.local != nil ? 1 : l.isTag ? 3 : 2 }
            return rank(a) < rank(b)
        }
    }

    var body: some View {
        let all = labels
        HStack(spacing: 4) {
            if let first = all.first {
                chip(first)
                if all.count > 1 {
                    Menu {
                        ForEach(all.dropFirst()) { label in
                            Menu(label.name) { actions(for: label) }
                        }
                    } label: {
                        Text("+\(all.count - 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(color.opacity(0.25)))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(all.dropFirst().map(\.name).joined(separator: ", "))
                }
                Rectangle().fill(color.opacity(0.6)).frame(height: 1.5)
            }
        }
    }

    private func chip(_ label: RefLabel) -> some View {
        HStack(spacing: 4) {
            if label.isHead && label.local != nil {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
            }
            Text(label.name)
                .font(.system(size: 11, weight: label.isHead ? .bold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if label.isTag {
                Image(systemName: "tag.fill").font(.system(size: 9))
            }
            if label.local != nil {
                Image(systemName: "laptopcomputer").font(.system(size: 9))
            }
            if !label.remotes.isEmpty {
                Image(systemName: "cloud.fill").font(.system(size: 9))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(label.local != nil || label.isTag ? 0.95 : 0.6)))
        .help(helpText(label))
        .onTapGesture(count: 2) { checkout(label) }
        .contextMenu { actions(for: label) }
        .layoutPriority(1)
    }

    private func helpText(_ label: RefLabel) -> String {
        var parts: [String] = []
        if let local = label.local { parts.append("Local: \(local)") }
        if !label.remotes.isEmpty { parts.append("Remote: " + label.remotes.joined(separator: ", ")) }
        if label.isTag { parts.append("Tag: \(label.name)") }
        if label.local != nil || !label.remotes.isEmpty { parts.append("Double-click to check out") }
        return parts.joined(separator: "\n")
    }

    private func branch(for label: RefLabel) -> Branch? {
        if let local = label.local { return model.branch(named: local, remote: false) }
        if let remote = label.remotes.first { return model.branch(named: remote, remote: true) }
        return nil
    }

    private func checkout(_ label: RefLabel) {
        if let branch = branch(for: label), !branch.isCurrent { model.checkout(branch) }
    }

    @ViewBuilder
    private func actions(for label: RefLabel) -> some View {
        if let branch = branch(for: label) {
            if !branch.isCurrent {
                Button("Checkout \(label.name)") { model.checkout(branch) }
                if let current = model.currentBranchName {
                    Button("Merge \(branch.name) into \(current)") { model.merge(branch) }
                }
            }
            Button("New Branch from \(branch.name)…") {
                model.newBranchRequest = NewBranchRequest(startPoint: branch.name)
            }
        }
        Button("Copy Name") { model.copyToPasteboard(label.name, what: label.name) }
    }
}

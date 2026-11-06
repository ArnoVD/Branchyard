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
    @ViewState private var width: CGFloat = 1200

    static let rowHeight: CGFloat = 28
    static let laneWidth: CGFloat = 16
    static let labelWidth: CGFloat = 190

    private var graphWidth: CGFloat {
        CGFloat(min(model.graphLanes, 10)) * Self.laneWidth + 12
    }

    /// Author, date and SHA drop out (SHA first) when the pane gets too narrow,
    /// so the commit message keeps at least 180 points.
    private var columns: GraphColumns {
        var room = width - Self.labelWidth - 10 - graphWidth - 18 - 180
        var c = GraphColumns(author: false, date: false, sha: false)
        if room >= 112 { c.date = true; room -= 112 }
        if room >= 104 { c.author = true; room -= 104 }
        if room >= 44 { c.sha = true }
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.searchOpen {
                CommitSearchBar(model: model)
                Divider()
            }
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
                                CommitRowView(model: model, row: row, graphWidth: graphWidth, columns: columns,
                                              isSelected: row.commit.sha == model.selectedCommitSHA,
                                              match: matchState(row.commit))
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
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { width = geo.size.width }
        })
    }

    /// nil: no search running. Otherwise whether this commit matches it.
    private func matchState(_ commit: Commit) -> Bool? {
        model.commitSearch.isEmpty ? nil : model.searchMatchSet.contains(commit.sha)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("BRANCH / TAG").frame(width: Self.labelWidth, alignment: .leading).padding(.leading, 10)
            Text("GRAPH").frame(width: graphWidth, alignment: .leading)
            Text("COMMIT MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
            if columns.author { Text("AUTHOR").frame(width: 104, alignment: .leading) }
            if columns.date { Text("DATE").frame(width: 112, alignment: .leading) }
            if columns.sha { Text("SHA").frame(width: 44, alignment: .leading) }
            Button { model.searchOpen ? model.closeSearch() : model.openSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.searchOpen ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search commits (⌘F)")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .background(Color.byPanel)
    }
}

/// Which optional columns fit in the graph pane.
private struct GraphColumns: Equatable {
    var author: Bool
    var date: Bool
    var sha: Bool
}

// MARK: - Row

private struct CommitRowView: View {
    @ObservedObject var model: RepoModel
    let row: GraphRow
    let graphWidth: CGFloat
    let columns: GraphColumns
    let isSelected: Bool
    /// nil: no search running; true/false: whether this commit matches it.
    let match: Bool?
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
            if columns.author {
                Text(commit.author)
                    .frame(width: 104, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if columns.date {
                Text(commit.isWIP ? "" : Self.relative(commit.date))
                    .frame(width: 112, alignment: .leading)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(commit.isWIP ? "" : commit.date.formatted(date: .abbreviated, time: .shortened))
            }
            if columns.sha {
                Text(commit.isWIP ? "" : commit.shortSHA)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 62, alignment: .leading)
                    .foregroundStyle(.tertiary)
            } else {
                Color.clear.frame(width: 18)
            }
        }
        .font(.system(size: 12))
        .frame(height: CommitGraphView.rowHeight)
        .opacity(match == false && !isSelected ? 0.35 : 1)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.commandKeyDown { model.commandClick(commit) } else { model.selectCommit(commit.sha) }
        }
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
            } else if match == true {
                Color.yellow.opacity(0.16)
            } else if hovering {
                Color.secondary.opacity(0.08)
            }
        }
    }

    @ViewBuilder
    private var compareMenu: some View {
        let side: CompareSide = commit.isWIP ? .workingCopy : .commit(commit)
        if let mark = model.compareMark, mark != side {
            Button("Compare with \(mark.title)") { model.compareMark = nil; model.commandClick(commit) }
        }
        if !commit.isWIP {
            Button("Compare with Working Copy") { model.compare(side, .workingCopy) }
            if !isHead, let head = model.graph.first(where: { $0.commit.sha == model.status.headOID })?.commit {
                Button("Compare with \(model.currentBranchName ?? "HEAD")") {
                    model.compare(side, model.branches.first(where: \.isCurrent).map(CompareSide.branch) ?? .commit(head))
                }
            }
            Button("Mark for Compare") { model.markForCompare(commit) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        compareMenu
        if !commit.isWIP || model.compareMark != nil { Divider() }
        if !commit.isWIP {
            Button("Create Branch Here…") { model.newBranchRequest = NewBranchRequest(startPoint: commit.sha) }
            Button("Create Tag Here…") { model.newTagRequest = NewTagRequest(sha: commit.sha, subject: commit.subject) }
            Divider()
            Group {
                if !isHead {
                    Button("Cherry-pick Commit") { model.cherryPick(commit) }
                }
                Button("Revert Commit") { model.revertCommit(commit) }
                Menu("Reset \(model.currentBranchName ?? "HEAD") to This Commit") {
                    Button("Soft – keep all changes, staged") { model.reset(to: commit, mode: .soft) }
                    Button("Mixed – keep working copy, reset index") { model.reset(to: commit, mode: .mixed) }
                    Button("Hard – discard all changes…") { model.hardResetRequest = commit }
                }
            }
            .disabled(model.busy != nil || model.opState != .none)
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

// MARK: - Search

/// "Search commits" field above the graph: matches light up, the rest fade.
private struct CommitSearchBar: View {
    @ObservedObject var model: RepoModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commits by message, author or SHA", text: $model.commitSearch)
                .textFieldStyle(.plain)
                .focused($focused)
                .layoutPriority(-1)
                .onSubmit { model.stepSearch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1); focused = true }
                .onKeyPress(.escape) { model.closeSearch(); return .handled }
                .onKeyPress(.downArrow) { model.stepSearch(1); return .handled }
                .onKeyPress(.upArrow) { model.stepSearch(-1); return .handled }
            if !model.commitSearch.isEmpty {
                Text(countText)
                    .font(.system(size: 11).monospacedDigit())
                    .fixedSize()
                    .foregroundStyle(model.searchMatches.isEmpty ? Color.orange : .secondary)
                Button { model.stepSearch(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧↩)")
                    .disabled(model.searchMatches.isEmpty)
                Button { model.stepSearch(1) } label: { Image(systemName: "chevron.down") }
                    .help("Next match (↩)")
                    .disabled(model.searchMatches.isEmpty)
            }
            Button { model.closeSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .help("Close search (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.byPanel)
        .onAppear { focused = true }
        .onChange(of: model.searchFocusRequest) { focused = true }
    }

    private var countText: String {
        let n = model.searchMatches.count
        guard n > 0 else { return "No matches" }
        if let i = model.searchIndex { return "\(i + 1) of \(n)" }
        return "\(n) match\(n == 1 ? "" : "es")"
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
            if !branch.isCurrent, let current = model.currentBranchName {
                Button("Compare \(branch.name) with \(current)") { model.compare(branch) }
            }
        }
        Button("Copy Name") { model.copyToPasteboard(label.name, what: label.name) }
    }
}

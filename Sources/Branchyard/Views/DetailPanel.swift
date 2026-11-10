import SwiftUI
import GitCore

/// Middle pane: the commit graph, or the diff of a picked file (working copy or commit).
struct DetailPanel: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        Group {
            if let request = model.comparison {
                CompareView(model: model, request: request)
            } else if let inspector = model.fileInspector {
                FileInspectorView(model: model, inspector: inspector)
            } else if let change = model.selectedChange {
                VStack(spacing: 0) {
                    DetailHeader(model: model, change: change)
                    Divider()
                    if let error = model.detailError {
                        ContentUnavailableView("Can't show this file", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                    } else if change.area == .conflicted {
                        ConflictResolverView(model: model, change: change)
                    } else {
                        DiffView(lines: model.diff, path: change.path, badge: change.area == .staged ? "Staged" : "Unstaged",
                                 lineActions: model.supportsLineStaging ? LineActions(
                                    staged: change.area == .staged,
                                    selected: $model.selectedLineIDs,
                                    apply: { ids, action, hunk in model.applyLines(ids, action, hunk: hunk) }) : nil)
                    }
                }
            } else if let file = model.selectedCommitFile, let commit = model.commitDetail?.commit {
                VStack(spacing: 0) {
                    CommitFileHeader(model: model, file: file, commit: commit)
                    Divider()
                    if let error = model.detailError {
                        ContentUnavailableView("Can't show this file", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                    } else {
                        DiffView(lines: model.diff, path: file.path, badge: commit.shortSHA)
                    }
                }
            } else {
                CommitGraphView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.byPane)
    }
}

/// "‹ Graph" button shown above any diff; Esc does the same.
struct BackToGraphButton: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        Button {
            model.closeDiff()
        } label: {
            Label("Graph", systemImage: "chevron.left")
        }
        .keyboardShortcut(.cancelAction)
        .help("Back to the commit graph (Esc)")
    }
}

private struct CommitFileHeader: View {
    @ObservedObject var model: RepoModel
    let file: CommitFile
    let commit: Commit

    var body: some View {
        HStack(spacing: 10) {
            BackToGraphButton(model: model)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName).font(.headline).lineLimit(1)
                Text(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text("in \(commit.shortSHA)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            InspectButtons(model: model, path: file.path, commit: commit.sha, canBlame: file.kind != .deleted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.byPanel)
    }
}

/// History and Blame buttons in a diff header.
private struct InspectButtons: View {
    @ObservedObject var model: RepoModel
    let path: String
    let commit: String?
    let canBlame: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.inspectFile(path, mode: .history, at: commit)
            } label: {
                Image(systemName: FileInspector.Mode.history.icon)
            }
            .help("File History")
            Button {
                model.inspectFile(path, mode: .blame, at: commit, blameAt: commit)
            } label: {
                Image(systemName: FileInspector.Mode.blame.icon)
            }
            .help(commit == nil ? "Blame" : "Blame at This Commit")
            .disabled(!canBlame)
        }
    }
}

private struct DetailHeader: View {
    @ObservedObject var model: RepoModel
    let change: FileChange

    var body: some View {
        HStack(spacing: 10) {
            BackToGraphButton(model: model)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.fileName).font(.headline).lineLimit(1)
                Text(change.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            switch change.area {
            case .unstaged:
                Button("Stage File") { model.stage([change]) }
            case .staged:
                Button("Unstage File") { model.unstage([change]) }
            case .conflicted:
                EmptyView()
            }
            if change.kind != .untracked && change.kind != .added {
                InspectButtons(model: model, path: change.path, commit: nil, canBlame: true)
            }
            Button {
                model.openInDefaultApp(change.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open in default app")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.byPanel)
    }
}

// MARK: - Diff

/// How Diff View lays out changes. File View ignores this and shows the whole new file.
enum DiffLayout: String, CaseIterable, Identifiable {
    case hunk, inline, split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hunk: return "Hunk View"
        case .inline: return "Inline View"
        case .split: return "Split View"
        }
    }

    var icon: String {
        switch self {
        case .hunk: return "list.bullet.rectangle"
        case .inline: return "text.justify.left"
        case .split: return "rectangle.split.2x1"
        }
    }
}

enum DiffColors {
    static var added: Color { Theme.current.added }
    static var removed: Color { Theme.current.removed }
}

/// Builds every layout from one full-context diff (`git diff -U1000000`).
enum DiffShaping {
    static func isBody(_ line: DiffLine) -> Bool {
        line.kind == .added || line.kind == .removed || line.kind == .context
    }

    /// The file's lines: context, added and removed. No headers.
    static func body(_ lines: [DiffLine]) -> [DiffLine] { lines.filter(isBody) }

    /// Only the changes plus `context` lines around them, each run under an `@@` header.
    static func hunks(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        let body = body(lines)
        let changed = body.indices.filter { body[$0].kind != .context }
        guard !changed.isEmpty else { return [] }

        var keep = [Bool](repeating: false, count: body.count)
        for i in changed {
            for j in max(0, i - context)...min(body.count - 1, i + context) { keep[j] = true }
        }

        var out: [DiffLine] = []
        var nextID = (lines.map(\.id).max() ?? 0) + 1
        var i = 0
        while i < body.count {
            guard keep[i] else { i += 1; continue }
            var end = i
            while end + 1 < body.count, keep[end + 1] { end += 1 }
            let run = body[i...end]
            let old = run.compactMap(\.oldNumber)
            let new = run.compactMap(\.newNumber)
            let header = "@@ -\(old.first ?? 0),\(old.count) +\(new.first ?? 0),\(new.count) @@"
            out.append(DiffLine(id: nextID, kind: .hunk, text: header, oldNumber: nil, newNumber: nil))
            nextID += 1
            out.append(contentsOf: run)
            i = end + 1
        }
        return out
    }

    /// The new file as it is now. A deleted file shows what it was.
    static func file(_ body: [DiffLine]) -> [DiffLine] {
        let current = body.filter { $0.kind != .removed }
        return current.isEmpty ? body : current
    }

    struct SplitRow: Identifiable {
        let id: Int
        let left: DiffLine?
        let right: DiffLine?
    }

    /// Old on the left, new on the right; a run of removed lines pairs up with the added lines after it.
    static func split(_ body: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        func flush() {
            for k in 0..<max(removed.count, added.count) {
                rows.append(SplitRow(id: rows.count,
                                     left: k < removed.count ? removed[k] : nil,
                                     right: k < added.count ? added[k] : nil))
            }
            removed.removeAll()
            added.removeAll()
        }

        for line in body {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            default:
                flush()
                rows.append(SplitRow(id: rows.count, left: line, right: line))
            }
        }
        flush()
        return rows
    }

    /// A new (or deleted) file: every line is added (or removed).
    static func wholeFile(_ body: [DiffLine]) -> DiffLine.Kind? {
        guard let first = body.first?.kind, first != .context,
              body.allSatisfy({ $0.kind == first }) else { return nil }
        return first
    }
}

/// Editor settings resolved once per diff, passed to every row.
struct DiffStyle {
    let font: Font
    let size: Double
    let tabSize: Int
    let lineNumbers: Bool
    let wrap: Bool
    let fileMode: Bool
    let language: SyntaxLanguage
    let palette: SyntaxPalette

    var numberWidth: CGFloat { max(34, size * 3.4) }

    func display(_ line: DiffLine) -> String {
        var text = line.text
        if DiffShaping.isBody(line), !text.isEmpty { text.removeFirst() }
        if text.contains("\t") { text = text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabSize)) }
        return text.isEmpty ? " " : text
    }

    /// Code lines get syntax colors; hunk headers and meta lines stay plain.
    func highlighted(_ line: DiffLine) -> AttributedString {
        let text = display(line)
        guard DiffShaping.isBody(line) else { return AttributedString(text) }
        return SyntaxHighlighter.highlight(text, language: language, palette: palette)
    }
}

/// Stage / unstage / discard single hunks or lines from a working-copy diff.
struct LineActions {
    let staged: Bool
    let selected: Binding<Set<Int>>
    /// (line ids, action, whole hunk?)
    let apply: (Set<Int>, LineAction, Bool) -> Void
}

struct DiffView: View {
    let lines: [DiffLine]
    /// File path, used to pick the language for syntax colors.
    var path: String? = nil
    /// "Unstaged", "Staged" or a commit SHA, shown at the left of the mode bar.
    var badge: String? = nil
    /// Working-copy diffs: hunk buttons and clickable lines (Hunk and Inline View only).
    var lineActions: LineActions? = nil
    /// Where a Shift-click range starts.
    @ViewState private var anchor: Int?

    @AppStorage("diffLayout") private var layout: DiffLayout = .hunk
    @AppStorage("diffFileView") private var fileView = false
    @AppStorage(EditorPrefs.fontKey) private var fontFamily = ""
    @AppStorage(EditorPrefs.sizeKey) private var fontSize = 12.0
    @AppStorage(EditorPrefs.tabKey) private var tabSize = 4
    @AppStorage(EditorPrefs.lineNumbersKey) private var lineNumbers = true
    @AppStorage(EditorPrefs.wrapKey) private var wordWrap = false
    @AppStorage(SyntaxPalette.key) private var syntaxTheme = ""

    var body: some View {
        VStack(spacing: 0) {
            DiffModeBar(badge: badge, layout: $layout, fileView: $fileView)
            Divider()
            content
            if let actions = activeLineActions, !actions.selected.wrappedValue.isEmpty {
                Divider()
                selectionBar(actions)
            }
        }
    }

    /// Line actions work on the unified layouts, where every changed line has its own row.
    private var activeLineActions: LineActions? {
        fileView || layout == .split ? nil : lineActions
    }

    private func selectionBar(_ actions: LineActions) -> some View {
        let ids = actions.selected.wrappedValue
        return HStack(spacing: 8) {
            Text(ids.count == 1 ? "1 line selected" : "\(ids.count) lines selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { actions.selected.wrappedValue = [] }
            if actions.staged {
                Button("Unstage Lines") { actions.apply(ids, .unstage, false) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Discard Lines") { actions.apply(ids, .discard, false) }
                Button("Stage Lines") { actions.apply(ids, .stage, false) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.byToolbar)
    }

    /// Click: pick or drop one line. Shift-click: pick every changed line from the last click.
    private func toggle(_ line: DiffLine, in rows: [DiffLine], actions: LineActions) {
        var picked = actions.selected.wrappedValue
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let anchor, let from = rows.firstIndex(where: { $0.id == anchor }),
           let to = rows.firstIndex(where: { $0.id == line.id }) {
            for row in rows[min(from, to)...max(from, to)] where row.kind == .added || row.kind == .removed {
                picked.insert(row.id)
            }
        } else if picked.contains(line.id) {
            picked.remove(line.id)
        } else {
            picked.insert(line.id)
        }
        anchor = line.id
        actions.selected.wrappedValue = picked
    }

    /// The changed line ids under each `@@` header row.
    private func hunkMembers(_ rows: [DiffLine]) -> [Int: Set<Int>] {
        var members: [Int: Set<Int>] = [:]
        var current: Int?
        for row in rows {
            if row.kind == .hunk { current = row.id; members[row.id] = [] }
            else if let current, row.kind == .added || row.kind == .removed { members[current]?.insert(row.id) }
        }
        return members
    }

    @ViewBuilder private var content: some View {
        let changes = DiffShaping.body(lines)
        if changes.isEmpty {
            ContentUnavailableView("No text changes", systemImage: "doc",
                                   description: Text("Binary file, mode change, or empty file."))
        } else if fileView {
            unified(DiffShaping.file(changes), style: style(fileMode: true))
        } else if layout == .split {
            SplitDiff(rows: DiffShaping.split(changes), style: style(fileMode: false))
        } else {
            unified(layout == .hunk ? DiffShaping.hunks(lines) : changes, style: style(fileMode: false))
        }
    }

    @ViewBuilder
    private func hunkButtons(_ ids: Set<Int>?, actions: LineActions?) -> some View {
        if let ids, !ids.isEmpty, let actions {
            if actions.staged {
                HunkButton(title: "Unstage Hunk", prominent: true) { actions.apply(ids, .unstage, true) }
            } else {
                HunkButton(title: "Discard Hunk", prominent: false) { actions.apply(ids, .discard, true) }
                HunkButton(title: "Stage Hunk", prominent: true) { actions.apply(ids, .stage, true) }
            }
        }
    }

    private func style(fileMode: Bool) -> DiffStyle {
        DiffStyle(font: EditorPrefs.font(family: fontFamily, size: fontSize), size: fontSize,
                  tabSize: tabSize, lineNumbers: lineNumbers, wrap: wordWrap, fileMode: fileMode,
                  language: SyntaxLanguage.forPath(path), palette: .named(syntaxTheme))
    }

    private func unified(_ rows: [DiffLine], style: DiffStyle) -> some View {
        let actions = style.fileMode ? nil : activeLineActions
        let members = actions == nil ? [:] : hunkMembers(rows)
        let picked = actions?.selected.wrappedValue ?? []
        return GeometryReader { geo in
            ScrollView(style.wrap ? [.vertical] : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { line in
                        let changed = line.kind == .added || line.kind == .removed
                        DiffRow(line: line, style: style,
                                selected: picked.contains(line.id),
                                onGutterClick: actions != nil && changed ? { toggle(line, in: rows, actions: actions!) } : nil,
                                hunkButtons: { hunkButtons(members[line.id], actions: actions) })
                    }
                }
                // At least as wide as the pane, so line colors run edge to edge; color stops at the last line.
                .frame(minWidth: geo.size.width, maxWidth: style.wrap ? geo.size.width : nil, alignment: .topLeading)
                .padding(.vertical, 4)
                .frame(minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }
}

/// `[Unstaged]  [File View | Diff View]  ……  [hunk] [inline] [split]`
private struct DiffModeBar: View {
    let badge: String?
    @Binding var layout: DiffLayout
    @Binding var fileView: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let badge {
                Text(badge)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.byAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.byAccent.opacity(0.16)))
            }
            HStack(spacing: 2) {
                segment("File View", selected: fileView) { fileView = true }
                segment("Diff View", selected: !fileView) { fileView = false }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))

            Spacer(minLength: 0)

            if !fileView {
                HStack(spacing: 2) {
                    ForEach(DiffLayout.allCases) { option in
                        Button {
                            layout = option
                        } label: {
                            Image(systemName: option.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(layout == option ? Color.byAccent : .secondary)
                                .frame(width: 28, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(layout == option ? Color.byAccent.opacity(0.18) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.byToolbar)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.byAccent.opacity(0.22) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small button on a hunk's `@@` row.
private struct HunkButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? Color.white : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(prominent ? Color.byAccent : Color.primary.opacity(0.10)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DiffRow<HunkButtons: View>: View {
    let line: DiffLine
    let style: DiffStyle
    var selected = false
    /// Set when the line can be picked for line staging: clicking the gutter toggles it.
    var onGutterClick: (() -> Void)? = nil
    @ViewBuilder var hunkButtons: () -> HunkButtons

    private var background: Color {
        if selected { return Color.byAccent.opacity(0.28) }
        switch line.kind {
        case .added: return DiffColors.added
        case .removed: return DiffColors.removed
        case .hunk: return Color.byAccent.opacity(0.10)
        default: return .clear
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .hunk, .meta, .fileHeader: return .secondary
        default: return .primary
        }
    }

    var body: some View {
        if line.kind == .fileHeader {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 0) {
                gutter
                Text(style.highlighted(line))
                    .foregroundStyle(foreground)
                    .fixedSize(horizontal: !style.wrap, vertical: style.wrap)
                    .frame(maxWidth: style.wrap ? .infinity : nil, alignment: .leading)
                    .padding(.trailing, 12)
                if line.kind == .hunk {
                    HStack(spacing: 6) { hunkButtons() }
                        .padding(.trailing, 12)
                        .frame(minHeight: style.size * 1.5)
                }
            }
            .font(style.font)
            .frame(maxWidth: .infinity, minHeight: style.size * 1.5, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Color.byAccent).frame(width: 3) }
            }
            .textSelection(.enabled)
        }
    }

    /// Line numbers and the +/- sign. Clickable for changed lines in a working-copy diff.
    @ViewBuilder private var gutter: some View {
        let content = HStack(alignment: .top, spacing: 0) {
            if style.lineNumbers {
                if style.fileMode {
                    number(line.newNumber ?? line.oldNumber)
                } else {
                    number(line.oldNumber)
                    number(line.newNumber)
                }
            }
            Text(selected ? "✓" : prefix)
                .frame(width: 16)
                .foregroundStyle(selected ? Color.byAccent : .secondary)
        }
        if let onGutterClick {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onGutterClick)
                .onHover { inside in
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
                .help("Click to pick this line, Shift-click for a range")
        } else {
            content
        }
    }

    private var prefix: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return ""
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: style.numberWidth, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

/// Old file left, new file right. Lines wrap so both sides stay aligned.
private struct SplitDiff: View {
    let rows: [DiffShaping.SplitRow]
    let style: DiffStyle

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        cell(row.left, number: row.left?.oldNumber)
                        Rectangle().fill(Color.byHairline).frame(width: 1)
                        cell(row.right, number: row.right?.newNumber)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func cell(_ line: DiffLine?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if style.lineNumbers {
                Text(number.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: style.numberWidth, alignment: .trailing)
                    .padding(.trailing, 8)
            }
            Text(line.map(style.highlighted) ?? AttributedString(" "))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .font(style.font)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: style.size * 1.5)
        .background(background(line))
        .textSelection(.enabled)
    }

    private func background(_ line: DiffLine?) -> Color {
        switch line?.kind {
        case .added?: return DiffColors.added
        case .removed?: return DiffColors.removed
        case nil: return Color.primary.opacity(0.04)
        default: return .clear
        }
    }
}

// MARK: - Conflicts

struct ConflictResolverView: View {
    @ObservedObject var model: RepoModel
    let change: FileChange
    @ViewState private var focus = 0

    private var bothSidesHaveFile: Bool { change.conflictCode == "UU" || change.conflictCode == "AA" }

    var body: some View {
        VStack(spacing: 0) {
            if let conflict = model.conflict, bothSidesHaveFile, !conflict.hunks.isEmpty {
                VSplitView {
                    ConflictSidesView(model: model, conflict: conflict, focus: min(focus, conflict.hunks.count - 1))
                        .frame(minHeight: 150, idealHeight: 360)
                    ConflictOutputView(model: model, change: change, conflict: conflict, focus: $focus)
                        .frame(minHeight: 140, idealHeight: 260)
                }
                .onChange(of: change.id) { focus = 0 }
            } else {
                wholeFileChooser
            }
        }
    }

    /// For delete/modify conflicts, or files without markers (binary, already edited).
    private var wholeFileChooser: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 34)).foregroundStyle(.orange)
            Text(change.conflictDescription.map { "Conflict: \($0)" } ?? "Conflict").font(.title3.bold())
            Text(explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button(oursLabel) { model.takeWholeFile(change, side: .ours) }
                Button(theirsLabel) { model.takeWholeFile(change, side: .theirs) }
            }
            .controlSize(.large)
            Button("I fixed it in my editor: mark resolved") { model.markResolvedAsIs(change) }
                .buttonStyle(.link)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        switch change.conflictCode {
        case "UD": return "You changed this file, but the other branch deleted it."
        case "DU": return "You deleted this file, but the other branch changed it."
        case "DD": return "Both branches deleted this file."
        default: return "No conflict markers found (binary file, or already edited). Pick a side or mark it resolved."
        }
    }

    private var oursLabel: String { change.conflictCode == "DU" || change.conflictCode == "DD" ? "Keep Deleted (ours)" : "Use Ours" }
    private var theirsLabel: String { change.conflictCode == "UD" || change.conflictCode == "DD" ? "Delete File (theirs)" : "Use Theirs" }
}

private enum ConflictStyle {
    static func tint(_ side: ConflictPicks.Side) -> Color { side == .ours ? .blue : .purple }
    static let font = Font.system(size: 12, design: .monospaced)

    enum Check { case none, some, all }

    static func check(_ lines: [ConflictPicks.Line], in picks: ConflictPicks) -> Check {
        let n = lines.filter(picks.contains).count
        return n == 0 ? .none : n == lines.count ? .all : .some
    }

    static func box(_ state: Check, _ tint: Color) -> some View {
        Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
            .foregroundStyle(state == .none ? Color.secondary : tint)
            .font(.system(size: 13))
    }

    static func display(_ line: String) -> String {
        line.isEmpty ? " " : line.replacingOccurrences(of: "\t", with: "    ")
    }
}

/// A and B side by side: every conflicting line has a checkbox; each conflict and each side has
/// one that picks all of its lines. Shared lines show on both sides, so the panes scroll together.
private struct ConflictSidesView: View {
    @ObservedObject var model: RepoModel
    let conflict: ConflictFile
    let focus: Int

    private typealias Side = ConflictPicks.Side
    private typealias Line = ConflictPicks.Line

    private struct Row: Identifiable {
        enum Kind { case text(String), header(ConflictFile.Hunk), line(ConflictFile.Hunk, Int) }
        let id: String
        let kind: Kind
        let numA: Int?
        let numB: Int?
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var a = 1, b = 1
        for (s, segment) in conflict.segments.enumerated() {
            switch segment {
            case .text(let lines):
                for (i, line) in lines.enumerated() {
                    rows.append(Row(id: "t\(s).\(i)", kind: .text(line), numA: a, numB: b))
                    a += 1
                    b += 1
                }
            case .conflict(let hunk):
                rows.append(Row(id: "h\(hunk.id)", kind: .header(hunk), numA: nil, numB: nil))
                for i in 0..<max(hunk.ours.count, hunk.theirs.count, 1) {
                    rows.append(Row(id: "l\(hunk.id).\(i)", kind: .line(hunk, i),
                                    numA: i < hunk.ours.count ? a + i : nil, numB: i < hunk.theirs.count ? b + i : nil))
                }
                a += hunk.ours.count
                b += hunk.theirs.count
            }
        }
        if case .text("")? = rows.last?.kind { rows.removeLast() }  // the file's final newline
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneHeader(.ours)
                Divider()
                paneHeader(.theirs)
            }
            .frame(height: 30)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 0) {
                                cell(row, .ours)
                                Divider()
                                cell(row, .theirs)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .id(row.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: focus) { proxy.scrollTo("h\(focus)", anchor: .top) }
            }
        }
    }

    private func paneHeader(_ side: Side) -> some View {
        let lines = conflict.hunks.flatMap { ConflictPicks.all(side, of: $0) }
        let label = side == .ours ? conflict.hunks[0].oursLabel : conflict.hunks[0].theirsLabel
        return HStack(spacing: 6) {
            Button { toggle(lines) } label: { ConflictStyle.box(ConflictStyle.check(lines, in: model.conflictPicks), ConflictStyle.tint(side)) }
                .buttonStyle(.plain)
                .help("Take every conflicting line from \(side == .ours ? "A" : "B")")
            Text(side == .ours ? "A" : "B")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .background(RoundedRectangle(cornerRadius: 3).fill(ConflictStyle.tint(side)))
            Text(side == .ours ? "Ours" : "Theirs").font(.callout.bold())
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cell(_ row: Row, _ side: Side) -> some View {
        let tint = ConflictStyle.tint(side)
        let num = side == .ours ? row.numA : row.numB
        switch row.kind {
        case .text(let text):
            line(num: num, text: text, check: nil, tint: tint)
                .foregroundStyle(.secondary)
        case .header(let hunk):
            let lines = ConflictPicks.all(side, of: hunk)
            let resolved = model.conflictPicks.isResolved(hunk.id)
            HStack(spacing: 6) {
                Button { toggle(lines) } label: { ConflictStyle.box(ConflictStyle.check(lines, in: model.conflictPicks), tint) }
                    .buttonStyle(.plain)
                    .help("Take all of this conflict's lines from \(side == .ours ? "A" : "B")")
                Text("Conflict \(hunk.id + 1) of \(conflict.hunks.count)").font(.caption.bold())
                if !resolved, side == .ours {
                    Text("pick lines from A, B or both").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.orange.opacity(resolved ? 0.06 : 0.18))
            .overlay(alignment: .top) { Rectangle().fill(Color.orange.opacity(resolved ? 0.3 : 0.8)).frame(height: 1) }
        case .line(let hunk, let i):
            let lines = side == .ours ? hunk.ours : hunk.theirs
            if i < lines.count || (lines.isEmpty && i == 0) {
                let pick = Line(hunk: hunk.id, side: side, index: lines.isEmpty ? Line.whole : i)
                let picked = model.conflictPicks.contains(pick)
                Group {
                    if lines.isEmpty {
                        line(num: nil, text: "(no lines on this side: pick to keep nothing)", check: picked, tint: tint)
                            .italic()
                            .foregroundStyle(.secondary)
                    } else {
                        line(num: num, text: lines[i], check: picked, tint: tint)
                    }
                }
                .background(tint.opacity(picked ? 0.24 : 0.08))
                .contentShape(Rectangle())
                .onTapGesture { model.conflictPicks.toggle(pick) }
            } else {
                line(num: nil, text: "", check: nil, tint: tint)
                    .background(Color.secondary.opacity(0.05))
            }
        }
    }

    private func line(num: Int?, text: String, check: Bool?, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ConflictStyle.box(check == true ? .all : .none, tint)
                .opacity(check == nil ? 0 : 1)
            Text(num.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)
            Text(ConflictStyle.display(text))
                .font(ConflictStyle.font)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toggle(_ lines: [Line]) {
        let all = ConflictStyle.check(lines, in: model.conflictPicks) == .all
        model.conflictPicks.set(lines, picked: !all)
    }
}

/// The result of the picks, with conflict navigation, hand editing and Save.
private struct ConflictOutputView: View {
    @ObservedObject var model: RepoModel
    let change: FileChange
    let conflict: ConflictFile
    @Binding var focus: Int

    private struct Row: Identifiable {
        let id: String
        let line: ConflictFile.OutputLine
        let num: Int?
    }

    private var editing: Bool { model.conflictEditedText != nil }
    private var open: Int { conflict.hunks.filter { !model.conflictPicks.isResolved($0.id) }.count }

    private var canSave: Bool {
        if let text = model.conflictEditedText {
            return !text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") }
        }
        return open == 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing {
                TextEditor(text: Binding(get: { model.conflictEditedText ?? "" }, set: { model.conflictEditedText = $0 }))
                    .font(ConflictStyle.font)
                    .scrollContentBackground(.hidden)
                    .padding(4)
            } else {
                output
            }
        }
    }

    private var header: some View {
        let n = conflict.hunks.count
        return HStack(spacing: 8) {
            Text("Output").font(.callout.bold())
            if editing {
                Text("edited by hand").font(.caption).foregroundStyle(.orange)
            } else if open > 0 {
                Text("\(open) unresolved").font(.caption).foregroundStyle(.orange)
            } else {
                Label("all resolved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            Spacer(minLength: 8)
            if !editing {
                Text("conflict \(min(focus, n - 1) + 1) of \(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { focus = (min(focus, n - 1) - 1 + n) % n } label: { Image(systemName: "chevron.up") }
                    .help("Previous conflict")
                Button { focus = (min(focus, n - 1) + 1) % n } label: { Image(systemName: "chevron.down") }
                    .help("Next conflict")
                Divider().frame(height: 16)
            }
            if editing {
                Button("Discard Edits") { model.conflictEditedText = nil }
                    .help("Go back to picking lines")
            } else {
                Button("Edit") { model.conflictEditedText = editableText() }
                    .help("Edit the output by hand")
            }
            Menu("Whole File") {
                Button("Use A (ours) for everything") { model.takeWholeFile(change, side: .ours) }
                Button("Use B (theirs) for everything") { model.takeWholeFile(change, side: .theirs) }
                Divider()
                Button("I fixed it in my editor: mark resolved") { model.markResolvedAsIs(change) }
            }
            .fixedSize()
            Button("Save") { model.saveResolution(for: change) }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .help(canSave ? "Save the output and mark the file resolved"
                      : editing ? "Remove the remaining conflict markers first" : "Pick lines for every conflict first")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var num = 1
        var seen = Set<Int>()
        for (i, line) in conflict.output(model.conflictPicks).enumerated() {
            var id = "x\(i)"
            switch line {
            case .text:
                rows.append(Row(id: id, line: line, num: num))
                num += 1
            case .picked(_, _, let hunk), .unresolved(let hunk):
                if seen.insert(hunk).inserted { id = "o\(hunk)" }
                if case .unresolved = line {
                    rows.append(Row(id: id, line: line, num: nil))
                } else {
                    rows.append(Row(id: id, line: line, num: num))
                    num += 1
                }
            }
        }
        if case .text("")? = rows.last?.line { rows.removeLast() }
        return rows
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        outputRow(row).id(row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: focus) { proxy.scrollTo("o\(focus)", anchor: .center) }
        }
    }

    @ViewBuilder
    private func outputRow(_ row: Row) -> some View {
        switch row.line {
        case .text(let text):
            line(row.num, text, bar: nil)
        case .picked(let text, let side, _):
            line(row.num, text, bar: ConflictStyle.tint(side))
                .background(ConflictStyle.tint(side).opacity(0.12))
        case .unresolved(let hunk):
            Button { focus = hunk } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Conflict \(hunk + 1): check lines in A or B above")
                    Spacer(minLength: 0)
                }
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func line(_ num: Int?, _ text: String, bar: Color?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(num.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            Text(ConflictStyle.display(text))
                .font(ConflictStyle.font)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 6)
        .overlay(alignment: .leading) { if let bar { Rectangle().fill(bar).frame(width: 3) } }
    }

    /// The output as text; conflicts with nothing picked keep their markers to edit by hand.
    private func editableText() -> String {
        var lines: [String] = []
        for line in conflict.output(model.conflictPicks) {
            switch line {
            case .text(let text), .picked(let text, _, _):
                lines.append(text)
            case .unresolved(let id):
                guard let hunk = conflict.hunks.first(where: { $0.id == id }) else { continue }
                lines.append("<<<<<<< \(hunk.oursLabel)")
                lines += hunk.ours
                lines.append("=======")
                lines += hunk.theirs
                lines.append(">>>>>>> \(hunk.theirsLabel)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

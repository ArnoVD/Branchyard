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

    private var bothSidesHaveFile: Bool { change.conflictCode == "UU" || change.conflictCode == "AA" }

    var body: some View {
        VStack(spacing: 0) {
            if let conflict = model.conflict, bothSidesHaveFile, !conflict.hunks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(conflict.segments.enumerated()), id: \.offset) { _, segment in
                            switch segment {
                            case .text(let lines):
                                ContextBlock(lines: lines)
                            case .conflict(let hunk):
                                HunkView(hunk: hunk, choice: Binding(
                                    get: { model.conflictChoices[hunk.id] },
                                    set: { model.conflictChoices[hunk.id] = $0 }
                                ), total: conflict.hunks.count)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                Divider()
                footer(conflict)
            } else {
                wholeFileChooser
            }
        }
    }

    private func footer(_ conflict: ConflictFile) -> some View {
        let done = conflict.hunks.filter { model.conflictChoices[$0.id] != nil }.count
        return HStack {
            Text("\(done) of \(conflict.hunks.count) conflicts chosen")
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Whole File") {
                Button("Use Ours for everything") { model.takeWholeFile(change, side: .ours) }
                Button("Use Theirs for everything") { model.takeWholeFile(change, side: .theirs) }
                Divider()
                Button("I fixed it in my editor: mark resolved") { model.markResolvedAsIs(change) }
            }
            .fixedSize()
            Button("Save & Mark Resolved") { model.saveResolution(for: change) }
                .buttonStyle(.borderedProminent)
                .disabled(done < conflict.hunks.count)
        }
        .padding(10)
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

private struct ContextBlock: View {
    let lines: [String]
    @ViewState private var expanded = false

    var body: some View {
        let shown = (expanded || lines.count <= 8) ? lines : Array(lines.prefix(3)) + ["…"] + Array(lines.suffix(3))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            if lines.count > 8 {
                Button(expanded ? "Collapse" : "Show \(lines.count - 6) more lines") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HunkView: View {
    let hunk: ConflictFile.Hunk
    @Binding var choice: ConflictFile.Resolution?
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Conflict \(hunk.id + 1) of \(total)").font(.caption.bold())
                Spacer()
                Picker("", selection: $choice) {
                    Text("Choose…").tag(ConflictFile.Resolution?.none)
                    ForEach(ConflictFile.Resolution.allCases) { r in
                        Text(r.label).tag(ConflictFile.Resolution?.some(r))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .top, spacing: 8) {
                side(title: "Ours · \(hunk.oursLabel)", lines: hunk.ours, tint: .blue,
                     selected: choice == .ours || choice == .oursThenTheirs || choice == .theirsThenOurs) {
                    choice = .ours
                }
                side(title: "Theirs · \(hunk.theirsLabel)", lines: hunk.theirs, tint: .purple,
                     selected: choice == .theirs || choice == .oursThenTheirs || choice == .theirsThenOurs) {
                    choice = .theirs
                }
            }
            if let base = hunk.base, !base.isEmpty {
                DisclosureGroup("Original (common ancestor)") {
                    code(base).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(choice == nil ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(choice == nil ? Color.orange : Color.green.opacity(0.6)))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func side(title: String, lines: [String], tint: Color, selected: Bool, pick: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Use this", action: pick).controlSize(.small)
            }
            code(lines.isEmpty ? ["(nothing)"] : lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(selected ? 0.18 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? tint : .clear, lineWidth: 1.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func code(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
    }
}

import SwiftUI
import GitCore

/// Middle pane: File History (commits that changed the file, with each change) or Blame
/// (who last changed every line).
struct FileInspectorView: View {
    @ObservedObject var model: RepoModel
    let inspector: FileInspector

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.inspectorError {
                ContentUnavailableView("Can't show this file", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                switch inspector.mode {
                case .history: FileHistoryPane(model: model, inspector: inspector)
                case .blame: BlamePane(model: model, inspector: inspector)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackToGraphButton(model: model)
            VStack(alignment: .leading, spacing: 1) {
                Text(inspector.fileName).font(.headline).lineLimit(1)
                let folder = (inspector.path as NSString).deletingLastPathComponent
                Text(folder.isEmpty ? "Repository root" : folder)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if model.inspectorLoading { ProgressView().controlSize(.small) }
            Picker("", selection: Binding(get: { inspector.mode }, set: { model.setInspectorMode($0) })) {
                ForEach(FileInspector.Mode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                model.openInDefaultApp(inspector.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open in default app")
            .disabled(inspector.blameRevision != nil && inspector.mode == .blame)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.byPanel)
    }
}

extension FileInspector.Mode {
    var icon: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .blame: "person.text.rectangle"
        }
    }
}

enum RelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func text(_ date: Date) -> String { formatter.localizedString(for: date, relativeTo: Date()) }
}

// MARK: - History

private struct FileHistoryPane: View {
    @ObservedObject var model: RepoModel
    let inspector: FileInspector

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 290)
            Divider()
            if let revision = model.fileRevisions.first(where: { $0.commit.sha == model.selectedRevisionSHA }) {
                DiffView(lines: model.revisionDiff, path: revision.file.path, badge: revision.commit.shortSHA)
            } else {
                Color.clear
            }
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedRevisionSHA }, set: { model.selectRevision($0) })) {
            ForEach(model.fileRevisions) { revision in
                RevisionRow(revision: revision, isHead: revision.commit.sha == model.status.headOID)
                    .tag(revision.commit.sha)
                    .background(RowMenu { menu(revision) })
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.fileRevisions.isEmpty && !model.inspectorLoading {
                Text("No commits yet").foregroundStyle(.tertiary)
            }
        }
    }

    private func menu(_ revision: FileRevision) -> [RowMenuItem] {
        var items: [RowMenuItem] = [
            .action("Show in Graph") { model.showInGraph(revision.commit.sha) },
        ]
        if revision.file.kind != .deleted {
            items.append(.action("Blame at This Commit") { model.blame(at: revision.commit.sha) })
        }
        items += [
            .divider,
            .action("Copy Commit SHA") { model.copyToPasteboard(revision.commit.sha, what: "Commit SHA \(revision.commit.shortSHA)") },
            .action("Copy Commit Message") { model.copyToPasteboard(revision.commit.subject, what: "Commit message") },
        ]
        return items
    }
}

private struct RevisionRow: View {
    let revision: FileRevision
    let isHead: Bool

    var body: some View {
        let commit = revision.commit
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(commit.subject)
                    .fontWeight(isHead ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if revision.file.kind != .modified {
                    Text(revision.file.kind.badgeTitle)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(revision.file.kind.tint))
                }
            }
            HStack(spacing: 4) {
                Text(commit.author).lineLimit(1)
                Text("·")
                Text(RelativeDate.text(commit.date)).lineLimit(1)
                Spacer(minLength: 4)
                Text(commit.shortSHA).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let from = revision.file.originalPath {
                Text("from \(from)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
        .help("\(commit.subject)\n\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
    }
}

extension ChangeKind {
    var badgeTitle: String {
        switch self {
        case .added, .untracked: "ADDED"
        case .deleted: "DELETED"
        case .renamed: "RENAMED"
        case .copied: "COPIED"
        default: "CHANGED"
        }
    }
}

// MARK: - Blame

private struct BlamePane: View {
    @ObservedObject var model: RepoModel
    let inspector: FileInspector

    @AppStorage(EditorPrefs.fontKey) private var fontFamily = ""
    @AppStorage(EditorPrefs.sizeKey) private var fontSize = 12.0
    @AppStorage(EditorPrefs.tabKey) private var tabSize = 4
    @AppStorage(SyntaxPalette.key) private var syntaxTheme = ""

    var body: some View {
        VStack(spacing: 0) {
            if let sha = inspector.blameRevision {
                revisionBar(sha)
                Divider()
            }
            if let blame = model.blame {
                if blame.lines.isEmpty {
                    ContentUnavailableView("Empty file", systemImage: "doc")
                } else {
                    lines(blame)
                }
            } else {
                Color.clear
            }
        }
    }

    private func revisionBar(_ sha: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text(sha.hasSuffix("^") ? "Version before \(String(sha.prefix(7)))" : "Version in \(String(sha.prefix(7)))")
            if let old = inspector.blamePath {
                Text("(as \(old))").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if FileManager.default.fileExists(atPath: model.repo.url.appendingPathComponent(inspector.path).path) {
                Button("Show Working Copy") { model.blameWorkingCopy() }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.byPanel)
    }

    private func lines(_ blame: Blame) -> some View {
        let style = BlameStyle(font: EditorPrefs.font(family: fontFamily, size: fontSize), size: fontSize,
                               tabSize: tabSize, language: SyntaxLanguage.forPath(inspector.path),
                               palette: .named(syntaxTheme), ages: BlameAges(blame))
        let digits = String(blame.lines.count).count
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blame.lines.enumerated()), id: \.element.id) { index, line in
                    let first = index == 0 || blame.lines[index - 1].sha != line.sha
                    BlameRow(model: model, line: line, origin: blame.origins[line.sha], startsBlock: first,
                             style: style, digits: digits)
                }
            }
            .padding(.bottom, 8)
        }
        .background(Color.byPane)
    }
}

/// Newer commits get a stronger color in the gutter.
private struct BlameAges {
    let oldest: Date
    let newest: Date

    init(_ blame: Blame) {
        let dates = blame.origins.values.filter { !$0.isUncommitted }.map(\.date)
        oldest = dates.min() ?? Date()
        newest = dates.max() ?? Date()
    }

    /// 0 (oldest) … 1 (newest or uncommitted).
    func heat(_ origin: Blame.Origin?) -> Double {
        guard let origin, !origin.isUncommitted else { return 1 }
        let span = newest.timeIntervalSince(oldest)
        guard span > 0 else { return 1 }
        return origin.date.timeIntervalSince(oldest) / span
    }
}

private struct BlameStyle {
    let font: Font
    let size: Double
    let tabSize: Int
    let language: SyntaxLanguage
    let palette: SyntaxPalette
    let ages: BlameAges

    var rowHeight: CGFloat { max(18, size * 1.55) }

    func highlighted(_ text: String) -> AttributedString {
        var text = text
        if text.contains("\t") { text = text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabSize)) }
        return SyntaxHighlighter.highlight(text.isEmpty ? " " : text, language: language, palette: palette)
    }
}

private struct BlameRow: View {
    @ObservedObject var model: RepoModel
    let line: Blame.Line
    let origin: Blame.Origin?
    let startsBlock: Bool
    let style: BlameStyle
    let digits: Int
    @ViewState private var hovering = false

    private var uncommitted: Bool { origin?.isUncommitted ?? true }

    var body: some View {
        HStack(spacing: 0) {
            gutter
            Text(String(line.number))
                .font(.system(size: max(9, style.size - 1), design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: CGFloat(digits) * style.size * 0.62 + 16, alignment: .trailing)
                .padding(.trailing, 10)
            Text(style.highlighted(line.text))
                .font(style.font)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: style.rowHeight)
        .background(uncommitted ? Color.green.opacity(0.07) : Color.clear)
        .overlay(alignment: .top) {
            if startsBlock && line.number > 1 { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
        }
    }

    private var gutter: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(uncommitted ? Color.green : Color.accentColor.opacity(0.15 + 0.85 * style.ages.heat(origin)))
                .frame(width: 3)
            if startsBlock, let origin {
                if uncommitted {
                    Text("Not committed yet").italic().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Text(origin.summary)
                        .lineLimit(1)
                        .foregroundStyle(hovering ? Color.accentColor : .primary)
                    Spacer(minLength: 4)
                    Text(origin.author).lineLimit(1).foregroundStyle(.secondary)
                        .frame(maxWidth: 90, alignment: .trailing)
                    Text(RelativeDate.text(origin.date)).lineLimit(1).foregroundStyle(.secondary)
                        .fixedSize()
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .padding(.trailing, 8)
        .frame(width: 360, height: style.rowHeight)
        .background(Color.byPanel.opacity(0.6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 && !uncommitted }
        .onTapGesture { if !uncommitted { model.showRevision(line.sha) } }
        .help(help)
        .contextMenu {
            if let origin, !uncommitted {
                Button("Show Change in File History") { model.showRevision(origin.sha) }
                Button("Show in Graph") { model.showInGraph(origin.sha) }
                Button("Blame Before This Commit") { model.blame(at: origin.sha + "^") }
                Divider()
                Button("Copy Commit SHA") { model.copyToPasteboard(origin.sha, what: "Commit SHA \(origin.shortSHA)") }
            }
        }
    }

    private var help: String {
        guard let origin, !uncommitted else { return "Not committed yet" }
        return "\(origin.shortSHA) \(origin.summary)\n\(origin.author) · \(origin.date.formatted(date: .abbreviated, time: .shortened))\nClick to see this change"
    }
}

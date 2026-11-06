import SwiftUI
import GitCore

/// Right-hand pane: unstaged files (conflicts first) on top, staged files below
/// (drag the divider to resize), and the commit box at the bottom.
struct ChangesPanel: View {
    @ObservedObject var model: RepoModel
    @ViewState private var toDiscard: FileChange?

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                section(
                    title: model.status.conflicted.isEmpty ? "Unstaged Files" : "Unstaged & Conflicts",
                    count: model.status.unstaged.count + model.status.conflicted.count,
                    action: model.status.unstaged.isEmpty ? nil : ("Stage All", { model.stageAll() }),
                    files: model.status.conflicted + model.status.unstaged,
                    empty: model.loaded && model.status.isClean ? "Working tree clean" : "No unstaged changes"
                )
                section(
                    title: "Staged Files",
                    count: model.status.staged.count,
                    action: model.status.staged.isEmpty ? nil : ("Unstage All", { model.unstageAll() }),
                    files: model.status.staged,
                    empty: "Nothing staged yet"
                )
            }
            .frame(maxHeight: .infinity)

            Divider()
            CommitBox(model: model)
        }
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            "Discard changes to \(toDiscard?.fileName ?? "")?",
            isPresented: Binding(get: { toDiscard != nil }, set: { if !$0 { toDiscard = nil } }),
            presenting: toDiscard
        ) { change in
            Button(change.kind == .untracked ? "Delete File" : "Discard Changes", role: .destructive) {
                model.discard(change)
            }
        } message: { change in
            Text(change.kind == .untracked
                 ? "This untracked file will be deleted. This can't be undone."
                 : "Your unstaged edits to this file will be lost. This can't be undone.")
        }
    }

    private func section(title: String, count: Int, action: (String, () -> Void)?,
                         files: [FileChange], empty: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                if let action {
                    Button(action.0, action: action.1)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.byPanel)
            Divider()
            List(selection: $model.selectedChangeID) {
                ForEach(files) { row($0) }
            }
            .listStyle(.inset)
            .overlay {
                if files.isEmpty {
                    Text(empty).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
    }

    private func row(_ change: FileChange) -> some View {
        FileRow(change: change) { model.toggleStage(change) }
            .tag(change.id)
            .contextMenu {
                switch change.area {
                case .unstaged:
                    Button("Stage") { model.stage([change]) }
                    Button(change.kind == .untracked ? "Delete File…" : "Discard Changes…") { toDiscard = change }
                case .staged:
                    Button("Unstage") { model.unstage([change]) }
                case .conflicted:
                    Button("Use Ours (whole file)") { model.takeWholeFile(change, side: .ours) }
                    Button("Use Theirs (whole file)") { model.takeWholeFile(change, side: .theirs) }
                    Button("Mark Resolved as Is") { model.markResolvedAsIs(change) }
                }
                Divider()
                Button("Open") { model.openInDefaultApp(change.path) }
                Button("Reveal in Finder") { model.revealInFinder(change.path) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(change.path, forType: .string)
                }
            }
    }
}

private struct FileRow: View {
    let change: FileChange
    let toggle: () -> Void

    private var tint: Color {
        switch change.kind {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        case .renamed, .copied: return .purple
        default: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(change.area == .conflicted ? "!" : change.kind.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(tint))
            VStack(alignment: .leading, spacing: 0) {
                Text(change.fileName).lineLimit(1)
                let detail = change.conflictDescription
                    ?? (change.originalPath.map { "from \($0)" })
                    ?? (change.directory.isEmpty ? nil : change.directory)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if change.area != .conflicted {
                Button(action: toggle) {
                    Image(systemName: change.area == .staged ? "minus.circle" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .help(change.area == .staged ? "Unstage" : "Stage")
            }
        }
        .help(change.path)
    }
}

private struct CommitBox: View {
    @ObservedObject var model: RepoModel
    @ObservedObject private var profiles = ProfileStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.commitMessage)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.byPane))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            let (profile, folder) = profiles.effective(forRepo: model.repo.url.path)
            HStack(spacing: 6) {
                ProfileAvatar(profile: profile, size: 16)
                Text(profiles.signature(of: profile))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .help(folder.map { "Profile \(profile.name), automatic for \(($0 as NSString).abbreviatingWithTildeInPath)" }
                  ?? "Commit author from profile \(profile.name)")
            HStack {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.commit()
                } label: {
                    Text(model.opState == .merging ? "Commit Merge" : "Commit \(model.status.staged.count) file(s)")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCommit)
            }
        }
        .padding(10)
    }

    private var hint: String {
        if !model.status.conflicted.isEmpty { return "Resolve conflicts first" }
        if model.status.staged.isEmpty && model.opState != .merging { return "Stage files to commit" }
        return "⌘↩ to commit"
    }
}

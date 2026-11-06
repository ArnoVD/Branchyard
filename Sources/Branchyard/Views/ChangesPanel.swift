import SwiftUI
import GitCore

/// Right-hand pane: unstaged files (conflicts first) on top, staged files below
/// (drag the divider to resize), and the commit box at the bottom.
struct ChangesPanel: View {
    @ObservedObject var model: RepoModel
    @ViewState private var toDiscard: [FileChange] = []

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                section(
                    title: model.status.conflicted.isEmpty ? "Unstaged Files" : "Unstaged & Conflicts",
                    files: model.status.conflicted + model.status.unstaged,
                    all: ("Stage", model.status.unstaged, { model.stage($0) }),
                    empty: model.loaded && model.status.isClean ? "Working tree clean" : "No unstaged changes"
                )
                section(
                    title: "Staged Files",
                    files: model.status.staged,
                    all: ("Unstage", model.status.staged, { model.unstage($0) }),
                    empty: "Nothing staged yet"
                )
            }
            .frame(maxHeight: .infinity)

            Divider()
            CommitBox(model: model)
        }
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            discardTitle,
            isPresented: Binding(get: { !toDiscard.isEmpty }, set: { if !$0 { toDiscard = [] } }),
            presenting: toDiscard
        ) { changes in
            Button(changes.allSatisfy { $0.kind == .untracked } ? "Delete" : "Discard", role: .destructive) {
                model.discard(changes)
            }
        } message: { changes in
            Text(discardMessage(changes))
        }
    }

    private var discardTitle: String {
        guard let first = toDiscard.first else { return "" }
        let what = toDiscard.count == 1 ? first.fileName : "\(toDiscard.count) files"
        return toDiscard.allSatisfy { $0.kind == .untracked } ? "Delete \(what)?" : "Discard changes to \(what)?"
    }

    private func discardMessage(_ changes: [FileChange]) -> String {
        let untracked = changes.filter { $0.kind == .untracked }.count
        let tracked = changes.count - untracked
        var parts: [String] = []
        if tracked > 0 { parts.append(tracked == 1 && changes.count == 1 ? "Your unstaged edits will be lost." : "Unstaged edits to \(tracked) file(s) will be lost.") }
        if untracked > 0 { parts.append(untracked == 1 && changes.count == 1 ? "This untracked file will be deleted." : "\(untracked) untracked file(s) will be deleted.") }
        return parts.joined(separator: " ") + " Undo (⌘Z) can bring them back."
    }

    /// Selection limited to this list: clicking in one list clears the other.
    private func selection(in files: [FileChange]) -> Binding<Set<String>> {
        let ids = Set(files.map(\.id))
        return Binding(
            get: { model.selectedChangeIDs.intersection(ids) },
            set: { model.setChangeSelection($0.intersection(ids)) }
        )
    }

    private func section(title: String, files: [FileChange],
                         all: (verb: String, files: [FileChange], run: ([FileChange]) -> Void),
                         empty: String) -> some View {
        let picked = files.filter { model.selectedChangeIDs.contains($0.id) && $0.area != .conflicted }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(files.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                if picked.count > 1 {
                    Button("\(all.verb) \(picked.count) Selected") { all.run(picked) }
                        .controlSize(.small)
                } else if !all.files.isEmpty {
                    Button("\(all.verb) All") { all.run(all.files) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.byPanel)
            Divider()
            List(selection: selection(in: files)) {
                ForEach(files) { change in
                    FileRow(change: change) { model.toggleStage(change) }
                        .background(RowMenu { menuItems(for: targets(of: change)) })
                        .tag(change.id)
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                let unstaged = model.selectedChanges.filter { $0.area == .unstaged }
                if !unstaged.isEmpty { toDiscard = unstaged }
            }
            .onKeyPress(.space) {
                let changes = model.selectedChanges.filter { $0.area != .conflicted }
                guard !changes.isEmpty else { return .ignored }
                if changes[0].area == .staged { model.unstage(changes) } else { model.stage(changes) }
                return .handled
            }
            .overlay {
                if files.isEmpty {
                    Text(empty).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
    }

    /// Right-click on a selected file acts on the whole selection, otherwise on that file only.
    private func targets(of change: FileChange) -> [FileChange] {
        model.selectedChangeIDs.contains(change.id) ? model.selectedChanges : [change]
    }

    private func menuItems(for changes: [FileChange]) -> [RowMenuItem] {
        let unstaged = changes.filter { $0.area == .unstaged }
        let staged = changes.filter { $0.area == .staged }
        let many = changes.count > 1
        var items: [RowMenuItem] = []
        if !unstaged.isEmpty {
            items.append(.action(many ? "Stage \(unstaged.count) Files" : "Stage") { model.stage(unstaged) })
            let title = unstaged.allSatisfy { $0.kind == .untracked }
                ? (many ? "Delete \(unstaged.count) Files…" : "Delete File…")
                : (many ? "Discard Changes to \(unstaged.count) Files…" : "Discard Changes…")
            items.append(.action(title) { toDiscard = unstaged })
        }
        if !staged.isEmpty {
            items.append(.action(many ? "Unstage \(staged.count) Files" : "Unstage") { model.unstage(staged) })
        }
        if changes.count == 1, let change = changes.first {
            if change.area == .conflicted {
                items.append(.action("Use Ours (whole file)") { model.takeWholeFile(change, side: .ours) })
                items.append(.action("Use Theirs (whole file)") { model.takeWholeFile(change, side: .theirs) })
                items.append(.action("Mark Resolved as Is") { model.markResolvedAsIs(change) })
            }
            items.append(.divider)
            items.append(.action("Open") { model.openInDefaultApp(change.path) })
            items.append(.action("Reveal in Finder") { model.revealInFinder(change.path) })
        } else {
            items.append(.divider)
        }
        items.append(.action(many ? "Copy \(changes.count) Paths" : "Copy Path") {
            model.copyToPasteboard(changes.map(\.path).joined(separator: "\n"),
                                   what: many ? "\(changes.count) paths" : changes[0].path)
        })
        let ignorable = changes.filter { $0.area != .conflicted && $0.kind != .deleted }
        if !ignorable.isEmpty {
            items.append(.divider)
            items.append(ignoreMenu(for: ignorable))
        }
        return items
    }

    /// "Ignore ▸" with the file, its extension and its folder. Tracked files are also
    /// removed from the index (kept on disk), or the ignore rule would do nothing.
    private func ignoreMenu(for changes: [FileChange]) -> RowMenuItem {
        let tracked = changes.contains { $0.kind != .untracked }
        let untrack: ([String]) -> [String] = { paths in tracked ? paths : [] }
        let verb = tracked ? "Stop Tracking and Ignore" : "Ignore"
        var entries: [RowMenuItem] = []
        if changes.count > 1 {
            let paths = changes.map(\.path)
            entries.append(.action("\(verb) \(changes.count) Files") {
                model.ignore(paths.map { "/" + $0 }, untrack: untrack(paths))
            })
        } else if let change = changes.first {
            entries.append(.action("\(verb) “\(change.fileName)”") {
                model.ignore(["/" + change.path], untrack: untrack([change.path]))
            })
            let ext = (change.fileName as NSString).pathExtension
            if !ext.isEmpty {
                // Untracks only this file: other tracked *.ext files are your call.
                entries.append(.action("\(verb) All “*.\(ext)” Files") {
                    model.ignore(["*.\(ext)"], untrack: untrack([change.path]))
                })
            }
            if !change.directory.isEmpty {
                let dir = change.directory
                entries.append(.action("\(verb) Folder “\(dir)/”") {
                    model.ignore(["/\(dir)/"], untrack: untrack([dir]))
                })
            }
        }
        return .submenu("Ignore", entries)
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
    @AppStorage("commit.pushAfter") private var pushAfter = false
    @AppStorage("commit.optionsOpen") private var optionsOpen = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.commitMessage)
                .focused($messageFocused)
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
            options
            HStack {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.commit(andPush: pushAfter)
                } label: {
                    Text(commitTitle)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCommit)
            }
        }
        .padding(10)
    }

    /// "˅ Commit options" with "☐ Push after committing" under it.
    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { optionsOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(optionsOpen ? 90 : 0))
                    Text("Commit options")
                    if !optionsOpen, !activeOptions.isEmpty {
                        Text("· " + activeOptions.joined(separator: ", ")).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if optionsOpen {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Amend previous commit", isOn: $model.amend)
                        .help("Replace the last commit with this message and the staged files")
                        .disabled(model.opState != .none)
                    Toggle("Push after committing", isOn: $pushAfter)
                        .help("Push the branch as soon as the commit is made")
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.leading, 14)
            }
            if model.amendRewritesPushed {
                Label("This commit is already pushed. Amending it means a force push.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 14)
            }
        }
        .onChange(of: model.amend) { _, on in if on { messageFocused = true } }
    }

    private var activeOptions: [String] {
        (model.amend ? ["amend"] : []) + (pushAfter ? ["push after committing"] : [])
    }

    private var commitTitle: String {
        let verb = model.amend ? "Amend" : "Commit"
        let what: String
        if model.opState == .merging { what = "Merge" }
        else if model.amend { what = model.status.staged.isEmpty ? "Message" : "with \(model.status.staged.count) file(s)" }
        else { what = "\(model.status.staged.count) file(s)" }
        return pushAfter ? "\(verb) \(what) and Push" : "\(verb) \(what)"
    }

    private var hint: String {
        if !model.status.conflicted.isEmpty { return "Resolve conflicts first" }
        if model.amend { return "⌘↩ to amend" }
        if model.status.staged.isEmpty && model.opState != .merging { return "Stage files to commit" }
        return "⌘↩ to commit"
    }
}

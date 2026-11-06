import SwiftUI
import AppKit
import GitCore

/// One row in the command palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var detail: String? = nil
    let icon: String
    let run: () -> Void
}

/// ⌘P: type to find an action or a branch, ↩ to run it.
struct CommandPalette: View {
    @ObservedObject var model: RepoModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Type a command or branch name", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { perform(results) }
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                row(command, selected: index == selection)
                                    .id(command.id)
                                    .onTapGesture {
                                        selection = index
                                        perform(results)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selection) {
                        if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) }
                    }
                }
                .frame(height: min(CGFloat(results.count) * 30 + 12, 340))
            }
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "select")
                hint("↩", "run")
                hint("esc", "close")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 560)
        .onAppear {
            focused = true
            if !PaletteDebug.query.isEmpty { query = PaletteDebug.query }
        }
        .onChange(of: query) { selection = 0 }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .frame(width: 18)
                .foregroundStyle(selected ? .white : .secondary)
            Text(command.title)
                .lineLimit(1)
                .foregroundStyle(selected ? .white : .primary)
            Spacer()
            if let detail = command.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func move(_ delta: Int, in results: [PaletteCommand]) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    /// Closes the palette first, so a command that opens a sheet can show it.
    private func perform(_ results: [PaletteCommand]) {
        guard results.indices.contains(selection) else { return }
        let command = results[selection]
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { command.run() }
    }

    // MARK: commands

    private var filtered: [PaletteCommand] {
        let all = commands
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { c -> (PaletteCommand, Int)? in
            Self.score(c.title.lowercased(), q).map { (c, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Higher is better; nil when the letters of `query` don't all appear in order.
    static func score(_ text: String, _ query: String) -> Int? {
        if text.hasPrefix(query) { return 1000 - text.count }
        if let range = text.range(of: query) {
            // A match at a word start beats one inside a word.
            let wordStart = range.lowerBound == text.startIndex
                || " /-_".contains(text[text.index(before: range.lowerBound)])
            return (wordStart ? 800 : 600) - text.count
        }
        var i = text.startIndex
        for ch in query {
            guard let found = text[i...].firstIndex(of: ch) else { return nil }
            i = text.index(after: found)
        }
        return 200 - text.count
    }

    private var commands: [PaletteCommand] {
        let m = model
        var list: [PaletteCommand] = [
            PaletteCommand(id: "fetch", title: "Fetch All", icon: "arrow.triangle.2.circlepath", run: { m.fetch() }),
            PaletteCommand(id: "pull", title: "Pull", detail: Repository.PullMode.preferred.title,
                           icon: "arrow.down.to.line", run: { m.pull() }),
            PaletteCommand(id: "push", title: "Push", detail: m.unpushed > 0 ? "\(m.unpushed) to push" : nil,
                           icon: "arrow.up.to.line", run: { m.push() }),
            PaletteCommand(id: "pr", title: "Create Pull Request", detail: m.currentBranchName,
                           icon: "arrow.triangle.pull", run: { m.createPullRequest() }),
            PaletteCommand(id: "branch", title: "New Branch…", icon: "arrow.triangle.branch",
                           run: { m.newBranchRequest = NewBranchRequest(startPoint: nil) }),
            PaletteCommand(id: "stash", title: "Stash Changes", icon: "tray.and.arrow.down", run: { m.stash() }),
            PaletteCommand(id: "pop", title: "Pop Stash", detail: m.stashes.first?.message,
                           icon: "tray.and.arrow.up", run: { m.pop() }),
            PaletteCommand(id: "search", title: "Search Commits", detail: "⌘F", icon: "magnifyingglass",
                           run: { m.openSearch() }),
            PaletteCommand(id: "refresh", title: "Refresh", detail: "⌘R", icon: "arrow.clockwise",
                           run: { Task { await m.refresh() } }),
        ]
        if let step = m.undoStack.last {
            list.append(PaletteCommand(id: "undo", title: "Undo", detail: step.title, icon: "arrow.uturn.backward", run: { m.undo() }))
        }
        if let step = m.redoStack.last {
            list.append(PaletteCommand(id: "redo", title: "Redo", detail: step.title, icon: "arrow.uturn.forward", run: { m.redo() }))
        }
        if let head = m.graph.first(where: { !$0.commit.isWIP })?.commit {
            list.append(PaletteCommand(id: "tag", title: "Create Tag at HEAD…", detail: head.shortSHA, icon: "tag",
                                       run: { m.newTagRequest = NewTagRequest(sha: head.sha, subject: head.subject) }))
        }
        list += [
            PaletteCommand(id: "publish", title: "Publish to GitHub…", icon: "icloud.and.arrow.up", run: { m.showPublish = true }),
            PaletteCommand(id: "terminal", title: "Open in Terminal", icon: "apple.terminal", run: { m.openInTerminal() }),
            PaletteCommand(id: "finder", title: "Reveal in Finder", icon: "folder", run: { m.revealInFinder() }),
        ]
        let current = m.currentBranchName
        for branch in m.localBranches where !branch.isCurrent {
            list.append(PaletteCommand(id: "co:" + branch.id, title: "Checkout \(branch.name)", detail: branch.relativeDate,
                                       icon: "arrow.triangle.branch", run: { m.checkout(branch) }))
        }
        let locals = Set(m.localBranches.map(\.name))
        for branch in m.branches where branch.isRemote && !locals.contains(branch.nameWithoutRemote)
            && branch.nameWithoutRemote != "HEAD" {
            list.append(PaletteCommand(id: "co:" + branch.id, title: "Checkout \(branch.name)", detail: "remote",
                                       icon: "cloud", run: { m.checkout(branch) }))
        }
        if let current {
            for branch in m.localBranches where !branch.isCurrent {
                list.append(PaletteCommand(id: "merge:" + branch.id, title: "Merge \(branch.name) into \(current)",
                                           icon: "arrow.triangle.merge", run: { m.merge(branch) }))
            }
            for branch in m.branches where !branch.isCurrent && branch.nameWithoutRemote != "HEAD" {
                list.append(PaletteCommand(id: "cmp:" + branch.id, title: "Compare \(branch.name) with \(current)",
                                           icon: "arrow.left.arrow.right", run: { m.compare(branch) }))
            }
        }
        if m.graphFilter.isSolo {
            list.append(PaletteCommand(id: "graph:exitSolo", title: "Exit Solo", icon: "scope", run: { m.exitSolo() }))
        } else if !m.graphFilter.isEmpty {
            list.append(PaletteCommand(id: "graph:showAll", title: "Show All Branches in Graph", icon: "eye",
                                       run: { m.showAllBranches() }))
        }
        for branch in m.branches where branch.nameWithoutRemote != "HEAD" {
            switch m.visibility(of: branch) {
            case .shown where !branch.isCurrent:
                list.append(PaletteCommand(id: "hide:" + branch.id, title: "Hide \(branch.name) in Graph",
                                           icon: "eye.slash", run: { m.hide([branch]) }))
            case .hidden:
                list.append(PaletteCommand(id: "show:" + branch.id, title: "Show \(branch.name) in Graph",
                                           icon: "eye", run: { m.show(branch) }))
            default: break
            }
            list.append(PaletteCommand(id: "solo:" + branch.id, title: "Solo \(branch.name)", icon: "scope",
                                       run: { m.solo([branch]) }))
        }
        return list
    }
}

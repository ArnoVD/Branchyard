import SwiftUI
import GitCore

/// Left panel: LOCAL, REMOTE, STASHES and TAGS sections. Branch names with "/" are grouped into folders.
/// Click a branch or tag to find it in the graph, double-click a branch to check it out, right-click for more.
struct BranchesPanel: View {
    @ObservedObject var model: RepoModel
    @ViewState private var selection: String?
    @ViewState private var filter = ""
    @ViewState private var collapsed: Set<String> = ["sec:remote", "sec:stashes", "sec:tags"]
    @ViewState private var branchToDelete: Branch?
    @ViewState private var stashToDrop: Stash?
    @ViewState private var tagToDelete: TagDeletion?

    /// A tag to delete locally (`remote == nil`) or from a remote.
    private struct TagDeletion: Identifiable {
        let tag: GitTag
        let remote: String?
        var id: String { tag.name + "@" + (remote ?? "") }
    }
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            filterField
            // Each open section scrolls on its own and fills the free height,
            // so the collapsed headers after it sit at the bottom of the panel.
            ForEach(sections, id: \.id) { section in
                let open = isOpen(section.id)
                SectionHeaderRow(node: SidebarNode(id: section.id, kind: .section(count: section.count),
                                                   title: section.title, icon: section.icon, depth: 0,
                                                   expanded: open),
                                 count: section.count)
                    .onTapGesture { toggle(section.id) }
                if open {
                    let rows = nodes(in: section.id)
                    list(rows)
                        // The last open section fills the panel, pushing later headers to the bottom.
                        // Earlier open sections only take their content height.
                        .frame(maxHeight: section.id == lastOpenSection
                               ? .infinity : max(CGFloat(rows.count) * 24 + 12, 36))
                        .layoutPriority(1)
                }
            }
            if lastOpenSection == nil { Spacer(minLength: 0) }
        }
        .background(Color.bySidebar)
        .onChange(of: selection) {
            if let branch = branch(for: selection) { model.revealInGraph(branch) }
            if let tag = tag(for: selection) { model.revealInGraph(tag) }
        }
        .onAppear {
            // Don't start with the cursor in the filter (it would take ↑/↓ from the graph).
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .confirmationDialog(
            "Delete branch \(branchToDelete?.name ?? "")?",
            isPresented: Binding(get: { branchToDelete != nil }, set: { if !$0 { branchToDelete = nil } }),
            presenting: branchToDelete
        ) { branch in
            Button("Delete") { model.deleteBranch(branch, force: false) }
            Button("Force Delete (lose unmerged commits)", role: .destructive) { model.deleteBranch(branch, force: true) }
        } message: { _ in
            Text("Only the local branch is deleted. Its remote branch stays.")
        }
        .confirmationDialog(
            "Drop this stash?",
            isPresented: Binding(get: { stashToDrop != nil }, set: { if !$0 { stashToDrop = nil } }),
            presenting: stashToDrop
        ) { stash in
            Button("Drop \(stash.ref)", role: .destructive) { model.drop(stash) }
        } message: { stash in
            Text("“\(stash.message)” will be deleted.")
        }
        .confirmationDialog(
            tagToDelete.map { $0.remote == nil ? "Delete tag \($0.tag.name)?" : "Delete tag \($0.tag.name) from \($0.remote!)?" } ?? "",
            isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } }),
            presenting: tagToDelete
        ) { target in
            Button("Delete", role: .destructive) {
                if let remote = target.remote { model.deleteRemoteTag(target.tag, from: remote) }
                else { model.deleteTag(target.tag) }
            }
        } message: { target in
            Text(target.remote == nil
                 ? "Only your local tag is deleted. The commit stays, and a pushed tag stays on the remote."
                 : "The tag is removed from \(target.remote!) for everyone. Your local tag stays.")
        }
    }

    // MARK: filter

    private var filterField: some View {
        HStack(spacing: 6) {
            TextField("Filter (⌘ + Option + f)", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($filterFocused)
                .onExitCommand { filter = ""; filterFocused = false }
                // AppKit focuses the first text field in a new window; the filter only on ⌘⌥F or a click.
                .onAppear { DispatchQueue.main.async { filterFocused = false } }
            if filter.isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            } else {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(filterFocused ? Color.byAccent : Color.byHairline, lineWidth: filterFocused ? 1.5 : 1))
        .padding(8)
        .background {
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .hidden()
        }
    }

    // MARK: tree

    private struct SectionInfo {
        let id: String
        let title: String
        let icon: String
        let count: Int
    }

    private var sections: [SectionInfo] {
        [
            SectionInfo(id: "sec:local", title: "Local", icon: "laptopcomputer", count: model.localBranches.count),
            SectionInfo(id: "sec:remote", title: "Remote", icon: "cloud", count: model.remoteGroups.count),
            SectionInfo(id: "sec:stashes", title: "Stashes", icon: "tray.full", count: model.stashes.count),
            SectionInfo(id: "sec:tags", title: "Tags", icon: "tag", count: model.tags.count),
        ]
    }

    private var lastOpenSection: String? { sections.last { isOpen($0.id) }?.id }

    private func isOpen(_ id: String) -> Bool { !filter.isEmpty || !collapsed.contains(id) }

    private func list(_ rows: [SidebarNode]) -> some View {
        List(selection: $selection) {
            ForEach(rows) { node in
                row(node)
                    .background(RowMenu { menuItems(for: node.id) })
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
        // The right-click menu comes from RowMenu on each row; this only handles double-click.
        .contextMenu(forSelectionType: String.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            if let branch = branch(for: ids.first) { model.checkout(branch) }
        }
        .overlay {
            if rows.isEmpty {
                Text(filter.isEmpty ? "None" : "No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The rows under one section header.
    private func nodes(in section: String) -> [SidebarNode] {
        var out: [SidebarNode] = []
        let filtering = !filter.isEmpty
        let isOpen: (String) -> Bool = { filtering || !collapsed.contains($0) }
        func matches(_ text: String) -> Bool { !filtering || text.localizedCaseInsensitiveContains(filter) }

        switch section {
        case "sec:local":
            let items = model.localBranches.filter { matches($0.name) }
                .map { (path: $0.name.split(separator: "/").map(String.init), branch: $0) }
            Self.appendTree(items, idPrefix: "local", depth: 1, isOpen: isOpen, into: &out)

        case "sec:remote":
            // One folder per remote, then the same folder tree.
            for group in model.remoteGroups {
                let branches = group.branches.filter { matches($0.name) }
                if filtering && branches.isEmpty { continue }
                let id = "f:remote:" + group.remote
                out.append(SidebarNode(id: id, kind: .folder, title: group.remote, icon: "server.rack",
                                       depth: 1, expanded: isOpen(id), dimmed: model.isRemoteHidden(group.remote)))
                if isOpen(id) {
                    let items = branches.map { (path: $0.nameWithoutRemote.split(separator: "/").map(String.init), branch: $0) }
                    Self.appendTree(items, idPrefix: "remote:" + group.remote, depth: 2, isOpen: isOpen, into: &out)
                }
            }

        case "sec:stashes":
            for stash in model.stashes where matches(stash.message) {
                out.append(SidebarNode(id: "s:" + stash.ref, kind: .stash(stash), title: stash.message,
                                       icon: "tray", depth: 1))
            }

        case "sec:tags":
            for tag in model.tags where matches(tag.name) {
                out.append(SidebarNode(id: "t:" + tag.name, kind: .tag(tag), title: tag.name, icon: "tag", depth: 1))
            }

        default:
            break
        }
        return out
    }

    /// "feature/ABC-1/thing" → folder feature › folder ABC-1 › branch thing. Folders and branches sort together.
    private static func appendTree(_ items: [(path: [String], branch: Branch)], idPrefix: String, depth: Int,
                                   isOpen: (String) -> Bool, into out: inout [SidebarNode]) {
        var leaves: [String: Branch] = [:]
        var folders: [String: [(path: [String], branch: Branch)]] = [:]
        for item in items {
            guard let head = item.path.first else { continue }
            if item.path.count == 1 {
                leaves[head] = item.branch
            } else {
                folders[head, default: []].append((path: Array(item.path.dropFirst()), branch: item.branch))
            }
        }
        let names = Set(leaves.keys).union(folders.keys)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            if let children = folders[name] {
                let prefix = idPrefix + "/" + name
                let id = "f:" + prefix
                out.append(SidebarNode(id: id, kind: .folder, title: name, icon: "folder", depth: depth, expanded: isOpen(id)))
                if isOpen(id) {
                    appendTree(children, idPrefix: prefix, depth: depth + 1, isOpen: isOpen, into: &out)
                }
            }
            if let branch = leaves[name] {
                out.append(SidebarNode(id: "b:" + branch.id, kind: .branch(branch), title: name,
                                       icon: "arrow.triangle.branch", depth: depth))
            }
        }
    }

    private func toggleVisibility(_ branch: Branch) {
        switch model.visibility(of: branch) {
        case .shown: model.hide([branch])
        case .hidden: model.show(branch)
        case .soloed: model.unsolo([branch])
        case .outsideSolo: model.solo([branch], adding: true)
        }
    }

    private func toggle(_ id: String) {
        guard filter.isEmpty else { return }
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    @ViewBuilder
    private func row(_ node: SidebarNode) -> some View {
        switch node.kind {
        case .section(let count):
            SectionHeaderRow(node: node, count: count)
        case .folder:
            FolderRow(node: node)
                .onTapGesture { toggle(node.id) }
                .selectionDisabled()
        case .branch(let branch):
            BranchRow(branch: branch, title: node.title, depth: node.depth,
                      visibility: model.visibility(of: branch)) { toggleVisibility(branch) }
                .tag(node.id)
                .listRowBackground(branch.isCurrent ? Color.green.opacity(0.2) : nil)
        case .stash(let stash):
            LeafRow(node: node)
                .help(stash.ref + ": " + stash.message)
                .tag(node.id)
        case .tag:
            LeafRow(node: node)
                .tag(node.id)
        }
    }

    // MARK: lookups + menus

    private func branch(for id: String?) -> Branch? {
        guard let id, id.hasPrefix("b:") else { return nil }
        return model.branches.first { $0.id == id.dropFirst(2) }
    }

    private func stash(for id: String?) -> Stash? {
        guard let id, id.hasPrefix("s:") else { return nil }
        return model.stashes.first { $0.ref == id.dropFirst(2) }
    }

    private func tag(for id: String?) -> GitTag? {
        guard let id, id.hasPrefix("t:") else { return nil }
        return model.tags.first { $0.name == id.dropFirst(2) }
    }

    private func visibilityItems(_ branch: Branch) -> [RowMenuItem] {
        var items: [RowMenuItem] = []
        switch model.visibility(of: branch) {
        case .shown:
            if !branch.isCurrent { items.append(.action("Hide in Graph") { model.hide([branch]) }) }
            items.append(.action("Solo") { model.solo([branch]) })
        case .hidden:
            items.append(.action("Show in Graph") { model.show(branch) })
            items.append(.action("Solo") { model.solo([branch]) })
        case .soloed:
            items.append(.action("Remove from Solo") { model.unsolo([branch]) })
            items.append(.action("Exit Solo") { model.exitSolo() })
        case .outsideSolo:
            items.append(.action("Add to Solo") { model.solo([branch], adding: true) })
            items.append(.action("Exit Solo") { model.exitSolo() })
        }
        if !model.graphFilter.isEmpty && !model.graphFilter.isSolo {
            items.append(.action("Show All Branches") { model.showAllBranches() })
        }
        return items
    }

    private func menuItems(for id: String) -> [RowMenuItem] {
        if let branch = branch(for: id) {
            var items: [RowMenuItem] = []
            if !branch.isCurrent {
                items.append(.action("Checkout \(branch.nameWithoutRemote)") { model.checkout(branch) })
                if let current = model.currentBranchName {
                    items.append(.action("Merge \(branch.name) into \(current)") { model.merge(branch) })
                }
            }
            if !branch.isCurrent, let current = model.currentBranchName {
                items.append(.action("Compare with \(current)") { model.compare(branch) })
            }
            items.append(.action("New Branch from \(branch.name)…") {
                model.newBranchRequest = NewBranchRequest(startPoint: branch.name)
            })
            if !branch.isRemote {
                items.append(.divider)
                if !model.remotes.isEmpty {
                    let target = branch.upstreamGone ? nil : branch.upstream
                    items.append(.action("Push \(branch.name)\(target.map { " to \($0)" } ?? "")") { model.pushBranch(branch) })
                    if branch.isCurrent {
                        items.append(.action("Create Pull Request") { model.createPullRequest() })
                    }
                }
                items.append(.action("Rename \(branch.name)…") {
                    model.branchRequest = BranchRequest(kind: .rename, branch: branch)
                })
                items.append(.action("Set Upstream…") {
                    model.branchRequest = BranchRequest(kind: .upstream, branch: branch)
                })
            }
            items.append(.divider)
            items += visibilityItems(branch)
            items.append(.divider)
            items.append(.action("Copy Name") { model.copyToPasteboard(branch.nameWithoutRemote, what: branch.nameWithoutRemote) })
            if !branch.isRemote && !branch.isCurrent {
                items.append(.divider)
                items.append(.action("Delete \(branch.name)…") { branchToDelete = branch })
            }
            return items
        } else if id.hasPrefix("f:remote:"), !id.dropFirst("f:remote:".count).contains("/") {
            let remote = String(id.dropFirst("f:remote:".count))
            return model.isRemoteHidden(remote)
                ? [.action("Show \(remote) Branches in Graph") { model.setRemote(remote, hidden: false) }]
                : [.action("Hide \(remote) Branches in Graph") { model.setRemote(remote, hidden: true) }]
        } else if let stash = stash(for: id) {
            return [
                .action("Pop") { model.pop(stash) },
                .action("Apply (keep stash)") { model.apply(stash) },
                .divider,
                .action("Drop…") { stashToDrop = stash },
            ]
        } else if let tag = tag(for: id) {
            var items: [RowMenuItem] = [
                .action("New Branch from \(tag.name)…") {
                    model.newBranchRequest = NewBranchRequest(startPoint: tag.name)
                },
                .divider,
            ]
            for remote in model.remotes {
                items.append(.action("Push \(tag.name) to \(remote)") { model.pushTag(tag, to: remote) })
            }
            items.append(.divider)
            items.append(.action("Copy Name") { model.copyToPasteboard(tag.name, what: tag.name) })
            items.append(.divider)
            items.append(.action("Delete \(tag.name)…") { tagToDelete = TagDeletion(tag: tag, remote: nil) })
            for remote in model.remotes {
                items.append(.action("Delete \(tag.name) from \(remote)…") {
                    tagToDelete = TagDeletion(tag: tag, remote: remote)
                })
            }
            return items
        }
        return []
    }
}

// MARK: - Rows

private struct SidebarNode: Identifiable {
    enum Kind {
        case section(count: Int)
        case folder
        case branch(Branch)
        case stash(Stash)
        case tag(GitTag)
    }
    let id: String
    let kind: Kind
    let title: String
    let icon: String
    let depth: Int
    var expanded = false
    /// Hidden from the graph.
    var dimmed = false

    /// Leading space so a leaf's icon lines up under its folder's icon.
    var indent: CGFloat { 10 + CGFloat(max(depth - 1, 0)) * 14 }
}

private struct Chevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 10)
    }
}

private struct SectionHeaderRow: View {
    let node: SidebarNode
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Chevron(expanded: node.expanded)
            Image(systemName: node.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(node.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.3)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.byAccent)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.bySidebar)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.byHairline).frame(height: 1)
        }
    }
}

private struct FolderRow: View {
    let node: SidebarNode

    var body: some View {
        HStack(spacing: 6) {
            Chevron(expanded: node.expanded)
            Image(systemName: node.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(node.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(node.dimmed ? 0.45 : 1)
            Spacer(minLength: 0)
            if node.dimmed {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Hidden from the graph. Right-click to show.")
            }
        }
        .padding(.leading, node.indent)
        .padding(.trailing, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
    }
}

private struct LeafRow: View {
    let node: SidebarNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(node.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, node.indent + 16)
        .padding(.trailing, 8)
        .frame(height: 24)
    }
}

private struct BranchRow: View {
    let branch: Branch
    let title: String
    let depth: Int
    let visibility: GraphVisibility
    let toggleVisibility: () -> Void
    @ViewState private var hovering = false

    private var dimmed: Bool { visibility == .hidden || visibility == .outsideSolo }

    var body: some View {
        HStack(spacing: 6) {
            if branch.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.green))
                    .frame(width: 16)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(title)
                .font(.system(size: 12.5, weight: branch.isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if branch.upstreamGone {
                Text("gone").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if branch.behind > 0 {
                Text("↓\(branch.behind)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            if branch.ahead > 0 {
                Text("↑\(branch.ahead)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            visibilityButton
        }
        .opacity(dimmed ? 0.5 : 1)
        .padding(.leading, 10 + CGFloat(max(depth - 1, 0)) * 14 + 16)
        .padding(.trailing, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(branch.name) · \(branch.shortSHA) · \(branch.relativeDate)"
              + (branch.upstream.map { "\ntracks \($0)" } ?? ""))
    }

    private var helpText: String {
        switch visibility {
        case .hidden: return "Show in graph"
        case .soloed: return "Remove from solo"
        case .outsideSolo: return "Add to solo"
        case .shown: return "Hide from graph"
        }
    }

    /// Always visible while hidden or soloed; on hover otherwise. The current branch can't be hidden.
    @ViewBuilder
    private var visibilityButton: some View {
        let icon: String? = switch visibility {
        case .hidden: "eye.slash"
        case .soloed: "scope"
        case .outsideSolo: hovering ? "plus.circle" : nil
        case .shown: hovering && !branch.isCurrent ? "eye" : nil
        }
        if let icon {
            Button(action: toggleVisibility) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(visibility == .soloed ? Color.byAccent : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }
}

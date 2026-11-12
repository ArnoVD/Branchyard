import SwiftUI
import GitCore

/// One repository: action bar on top, then branches | diff | changes.
struct RepoView: View {
    @ObservedObject var model: RepoModel
    /// You reopened the branches while a diff is showing; folds again once the diff closes.
    @ViewState private var branchesOpenDuringDiff = false
    @AppStorage("layout.branchesWidth") private var branchesWidth: Double = 280
    @AppStorage("layout.changesWidth") private var changesWidth: Double = 340
    private static let branchesRange: ClosedRange<Double> = 220...440
    private static let changesRange: ClosedRange<Double> = 280...560
    private static let middleMin: Double = 380

    var body: some View {
        VStack(spacing: 0) {
            if let request = model.pushTarget {
                PushTargetBar(model: model, request: request)
                    .id(request.branch)
            }
            ActionBar(model: model)
            if model.opState != .none {
                OperationBanner(model: model)
            }
            if let notice = model.notice {
                Banner(text: notice, systemImage: "info.circle", tint: .blue) { model.notice = nil }
            }
            Divider()
            // branches | graph (or a diff) | files to stage + commit (or the picked commit).
            // A file's diff gets the room: branches fold into a thin rail until you open them again.
            // Own layout instead of HSplitView, which hands freed space to the right panel.
            GeometryReader { geo in
                let folded = model.showsFileDiff && !branchesOpenDuringDiff
                let total = geo.size.width
                let right = min(changesWidth, max(Self.changesRange.lowerBound,
                                                  total - (folded ? 37 : Self.branchesRange.lowerBound + 1) - Self.middleMin - 1))
                let left = folded ? 36 : min(branchesWidth, max(Self.branchesRange.lowerBound, total - right - Self.middleMin - 2))
                HStack(spacing: 0) {
                    if folded {
                        BranchesRail { branchesOpenDuringDiff = true }
                            .frame(width: left)
                        Divider()
                    } else {
                        BranchesPanel(model: model)
                            .frame(width: left)
                        PaneDivider(width: $branchesWidth, shown: left, grows: .right,
                                    range: Self.branchesRange.lowerBound...min(Self.branchesRange.upperBound, total - right - Self.middleMin - 2))
                    }
                    DetailPanel(model: model)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .clipped()
                    PaneDivider(width: $changesWidth, shown: right, grows: .left,
                                range: Self.changesRange.lowerBound...min(Self.changesRange.upperBound, total - left - Self.middleMin - 2))
                    Group {
                        if model.showsCommitDetail {
                            CommitDetailPanel(model: model)
                        } else {
                            ChangesPanel(model: model)
                        }
                    }
                    .frame(width: right)
                    .frame(maxHeight: .infinity)
                    .background(Color.byPanel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                ToastStack(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if !model.loaded { await model.refresh() }
        }
        .onChange(of: model.showsFileDiff) {
            if !model.showsFileDiff { branchesOpenDuringDiff = false }
        }
        .onChange(of: model.selectedChangeID) {
            Task { await model.loadDetail() }
        }
        .onChange(of: model.selectedCommitFileID) {
            Task { await model.loadDetail() }
        }
        .sheet(item: $model.newBranchRequest) { request in
            NewBranchSheet(model: model, startPoint: request.startPoint)
        }
        .sheet(isPresented: $model.showPublish) {
            PublishSheet(model: model)
        }
        .sheet(item: $model.newTagRequest) { request in
            NewTagSheet(model: model, request: request)
        }
        .sheet(item: $model.branchRequest) { request in
            switch request.kind {
            case .rename: RenameBranchSheet(model: model, branch: request.branch)
            case .upstream: UpstreamSheet(model: model, branch: request.branch)
            }
        }
        .confirmationDialog("The remote has commits you don't have",
                            isPresented: Binding(get: { model.forcePushOffer != nil },
                                                 set: { if !$0 { model.forcePushOffer = nil } }),
                            presenting: model.forcePushOffer) { offer in
            Button("Force Push", role: .destructive) { model.forcePush(offer) }
            Button("Pull First") { model.pull() }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text("Pushing to \(offer.target) was rejected. Force push replaces the remote branch with yours: "
                 + "commits only on the remote are lost there. Pull first to keep them.")
        }
        .confirmationDialog("Reset \(model.currentBranchName ?? "HEAD") to \(model.hardResetRequest?.shortSHA ?? "")?",
                            isPresented: Binding(get: { model.hardResetRequest != nil },
                                                 set: { if !$0 { model.hardResetRequest = nil } }),
                            presenting: model.hardResetRequest) { commit in
            Button("Reset Hard", role: .destructive) { model.reset(to: commit, mode: .hard) }
            Button("Cancel", role: .cancel) {}
        } message: { commit in
            Text("Moves the branch to “\(commit.subject)” and throws away all changes to tracked files. "
                 + "Untracked files stay. Undo brings the branch and the changes back.")
        }
        .sheet(isPresented: $model.showPalette) {
            CommandPalette(model: model)
        }
        .alert("Git", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Pane layout

/// The line between two panes; drag it to resize the side panel it belongs to.
private struct PaneDivider: View {
    enum Side { case left, right }
    @Binding var width: Double
    /// The width the panel is drawn at now (may be less than `width` in a narrow window).
    let shown: Double
    /// Dragging toward this side makes the panel wider.
    let grows: Side
    let range: ClosedRange<Double>
    @ViewState private var start: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let base = start ?? shown
                                start = base
                                let delta = grows == .right ? drag.translation.width : -drag.translation.width
                                let upper = max(range.lowerBound, range.upperBound)
                                width = min(max(base + delta, range.lowerBound), upper)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .zIndex(1)
    }
}

// MARK: - Branches rail

/// What's left of the branches panel while a diff is open: one button to bring it back.
private struct BranchesRail: View {
    let expand: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: expand) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Show branches")
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.byPanel)
    }
}

// MARK: - Action bar

/// Top bar: `repository ▾ › branch ▾` on the left, git actions centered, Terminal on the right.
private struct ActionBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RepoModel
    @AppStorage(Repository.PullMode.storageKey) private var pullModeRaw = Repository.PullMode.merge.rawValue

    private var currentPullMode: Repository.PullMode { Repository.PullMode(rawValue: pullModeRaw) ?? .merge }

    var body: some View {
        HStack(spacing: 0) {
            // Left: where you are.
            HStack(spacing: 10) {
                repoMenu
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                branchMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Middle: what you can do.
            HStack(spacing: 4) {
                tool("Undo", "arrow.uturn.backward", .undo,
                     help: model.undoStack.last.map { "Undo \($0.title)" } ?? "Nothing to undo") { model.undo() }
                    .disabled(model.undoStack.isEmpty)
                tool("Redo", "arrow.uturn.forward", .redo,
                     help: model.redoStack.last.map { "Redo \($0.title)" } ?? "Nothing to redo") { model.redo() }
                    .disabled(model.redoStack.isEmpty)
                Rectangle().fill(Color.byHairline).frame(width: 1, height: 30).padding(.horizontal, 8)
                HStack(spacing: 0) {
                    tool("Pull", "arrow.down.to.line", .pull, also: .fetch, badge: model.status.behind,
                         help: "Pull (\(currentPullMode.title.lowercased()))") { model.pull() }
                    Menu {
                        Button("Fetch All") { model.fetch() }
                        Divider()
                        Section("Pull") {
                            ForEach(Repository.PullMode.allCases, id: \.self) { mode in
                                Toggle(mode.title, isOn: Binding(get: { currentPullMode == mode },
                                                                 set: { _ in model.pull(mode: mode) }))
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.top, 16)
                    .disabled(model.busy != nil)
                    .help("Fetch, or pick how Pull works")
                }
                tool("Push", "arrow.up.to.line", .push, badge: model.unpushed, highlight: model.unpushed > 0,
                     help: pushHelp) { model.push() }
                tool("Branch", "arrow.triangle.branch", .branch) { model.newBranchRequest = NewBranchRequest(startPoint: nil) }
                tool("Stash", "tray.and.arrow.down", .stash) { model.stash() }
                    .disabled(model.status.isClean && model.busyAction != .stash)
                tool("Pop", "tray.and.arrow.up", .pop, badge: model.stashes.count) { model.pop() }
                    .disabled(model.stashes.isEmpty && model.busyAction != .pop)
                ToolButton("Pull Request", "arrow.triangle.pull",
                           help: "Open a pull request for \(model.status.branch ?? "this branch") on GitHub or Bitbucket") {
                    model.createPullRequest()
                }
                .disabled(model.busy != nil || model.status.branch == nil || model.remotes.isEmpty)
                Rectangle().fill(Color.byHairline).frame(width: 1, height: 30).padding(.horizontal, 8)
                ToolButton("Terminal", "apple.terminal") { model.openInTerminal() }
            }
            .fixedSize()

            // Right: progress + extras.
            HStack(spacing: 10) {
                if let busy = model.busy, model.busyAction == nil {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Fetch All") { model.fetch() }
                    Divider()
                    Button("Publish to GitHub…") { model.showPublish = true }
                    Button("Create Pull Request") { model.createPullRequest() }
                        .disabled(model.status.branch == nil || model.remotes.isEmpty)
                    Divider()
                    Button("Search Commits") { model.openSearch() }
                    Button("Command Palette…") { model.showPalette = true }
                    Divider()
                    Button("Reveal in Finder") { model.revealInFinder() }
                    Button("Open in Terminal") { model.openInTerminal() }
                } label: {
                    VStack(spacing: 3) {
                        Text("Actions").font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: "ellipsis.circle").font(.system(size: 16)).frame(height: 18)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.byToolbar)
    }

    /// A toolbar button for a git operation: spins while its operation runs, locked while another does.
    private func tool(_ title: String, _ icon: String, _ action: ToolAction, also: ToolAction? = nil,
                      badge: Int = 0, highlight: Bool = false, help: String? = nil,
                      perform: @escaping () -> Void) -> some View {
        let running = model.busyAction != nil && (model.busyAction == action || model.busyAction == also)
        return ToolButton(title, icon, badge: running ? 0 : badge, highlight: highlight && !running,
                          help: help, running: running, action: perform)
            .disabled(model.busy != nil && !running)
    }

    private var pushHelp: String {
        let n = model.unpushed
        guard n > 0 else { return "Push" }
        let commits = "\(n) commit\(n == 1 ? "" : "s")"
        return model.status.upstream.map { "\(commits) waiting to be pushed to \($0)" }
            ?? "\(commits) not on any remote yet. Push to publish \(model.status.branch ?? "this branch")"
    }

    private var repoMenu: some View {
        Menu {
            Section("Open Tabs") {
                ForEach(state.tabs) { tab in
                    Button {
                        state.selectedTabID = tab.id
                    } label: {
                        if tab.id == model.id { Label(tab.name, systemImage: "checkmark") } else { Text(tab.name) }
                    }
                }
            }
            Divider()
            Button("Open Another Repository…") { state.promptAddRepository() }
            Button("Clone from Bitbucket…") { state.showClone = true }
        } label: {
            crumb(caption: "repository", title: model.name)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch repository")
    }

    private var branchMenu: some View {
        Menu {
            Section("Checkout") {
                ForEach(model.localBranches) { branch in
                    Button {
                        if !branch.isCurrent { model.checkout(branch) }
                    } label: {
                        if branch.isCurrent { Label(branch.name, systemImage: "checkmark") } else { Text(branch.name) }
                    }
                }
            }
            Divider()
            Button("New Branch…") { model.newBranchRequest = NewBranchRequest(startPoint: nil) }
        } label: {
            crumb(caption: model.status.upstream.map { "branch · tracks \($0)" } ?? "branch · no upstream",
                  title: model.status.branch ?? "Detached HEAD")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.busy != nil)
        .help("Switch branch")
    }

    private func crumb(caption: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ToolButton: View {
    let title: String
    let icon: String
    let badge: Int
    /// Something is waiting for this button (unpushed commits): tint it and ring it.
    let highlight: Bool
    let helpText: String?
    let running: Bool
    let action: () -> Void

    init(_ title: String, _ icon: String, badge: Int = 0, highlight: Bool = false, help: String? = nil,
         running: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.badge = badge
        self.highlight = highlight
        self.helpText = help
        self.running = running
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // Label above the icon.
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: highlight ? .semibold : .regular))
                    .foregroundStyle(highlight ? AnyShapeStyle(Color.byAccent) : AnyShapeStyle(.secondary))
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(highlight ? AnyShapeStyle(Color.byAccent) : AnyShapeStyle(.primary))
                    .frame(height: 18)
                    // While running, a spinner takes the icon's place.
                    .opacity(running ? 0 : 1)
                    .scaleEffect(running ? 0.6 : 1)
                    .overlay {
                        if running {
                            Spinner()
                                .frame(width: 16, height: 16)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: running)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(Color.byAccent))
                                .offset(x: 10, y: -5)
                        }
                    }
            }
            .frame(minWidth: 42)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                if highlight {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.byAccent.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.byAccent.opacity(0.45)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .allowsHitTesting(!running)
        .help(helpText ?? title)
    }
}

/// A ring with a gap, turning: the "working on it" mark on a toolbar button.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / 0.9
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.primary.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}

// MARK: - Toasts

/// Notifications in the bottom-left corner, newest at the bottom; each fades out after a few seconds.
private struct ToastStack: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastCard(toast: toast) { model.dismissToast(toast) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .leading))))
            }
        }
        .padding(14)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.toasts)
    }
}

private struct ToastCard: View {
    let toast: Toast
    let dismiss: () -> Void

    private var tint: Color {
        switch toast.kind {
        case .success: Color(red: 0.36, green: 0.66, blue: 0.36)
        case .info: Color(red: 0.33, green: 0.47, blue: 0.97)
        case .failure: Color(red: 0.86, green: 0.30, blue: 0.30)
        }
    }

    private var symbol: String {
        switch toast.kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .failure: "exclamationmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                tint
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text(toast.title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link = toast.link {
                    Link("Open on GitHub", destination: link)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 8)
            .help("Dismiss")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320)
        .background(Color.byToolbar)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.byHairline))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

// MARK: - Banners

private struct OperationBanner: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.opState.label).bold()
            Text(model.status.conflicted.isEmpty
                 ? (model.opState == .merging ? "All conflicts resolved. Commit to finish the merge." : "All conflicts resolved. Continue to finish.")
                 : "\(model.status.conflicted.count) file(s) still have conflicts.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Abort", role: .destructive) { model.abortOperation() }
            if model.opState != .merging {
                Button("Continue") { model.continueOperation() }
                    .disabled(!model.status.conflicted.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}

/// First push of a branch: which remote and remote branch it should push to and pull from.
private struct PushTargetBar: View {
    @ObservedObject var model: RepoModel
    @ViewState private var request: PushTargetRequest
    @FocusState private var focused: Bool

    init(model: RepoModel, request: PushTargetRequest) {
        self.model = model
        _request = ViewState(initialValue: request)
    }

    private var valid: Bool {
        let name = request.target.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !name.contains(" ") && !name.hasPrefix("-")
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("What remote/branch should “\(request.branch)” push to and pull from?")
                .lineLimit(1)
                .truncationMode(.middle)
            Picker("Remote", selection: $request.remote) {
                ForEach(request.remotes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Text("/").foregroundStyle(.secondary)
            TextField("branch", text: $request.target)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit { if valid { model.push(to: request) } }
            Button("Push") { model.push(to: request) }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || model.busy != nil)
            Button("Cancel") { model.pushTarget = nil }
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.18))
        .onAppear { focused = true }
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }
}

// MARK: - New branch

private struct NewBranchSheet: View {
    @ObservedObject var model: RepoModel
    let startPoint: String?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var exists: Bool { model.localBranches.contains { $0.name == trimmed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch").font(.title3.bold())
            Text("From \(startPoint ?? model.status.branch ?? "HEAD"), then switch to it.")
                .foregroundStyle(.secondary)
            TextField("feature/my-change", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if exists {
                Text("A branch with that name already exists.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Branch", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed.contains(" ") || exists)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        guard !trimmed.isEmpty, !trimmed.contains(" "), !exists else { return }
        model.createBranch(trimmed, from: startPoint)
        dismiss()
    }
}

// MARK: - Publish to GitHub

/// Creates a GitHub repository for this repo on the active profile's account, then pushes.
private struct PublishSheet: View {
    @ObservedObject var model: RepoModel
    @ObservedObject private var store = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.tabKey) private var settingsTab = "appearance"
    @AppStorage(AccountsSettings.profileKey) private var accountsTarget = ""

    @ViewState private var name = ""
    @ViewState private var description = ""
    @ViewState private var isPrivate = true

    private var validName: Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    var body: some View {
        let (profile, folder) = store.effective(forRepo: model.repo.url.path)
        VStack(alignment: .leading, spacing: 14) {
            Text("Publish to GitHub").font(.title3.weight(.semibold))
            if let login = profile.gitHubLogin {
                HStack(spacing: 8) {
                    ProfileAvatar(profile: profile, size: 20)
                    Text("@\(login)").fontWeight(.medium)
                    Text("· profile \(profile.name)").foregroundStyle(.secondary)
                }
                Form {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, prompt: Text("Optional"))
                    Picker("Visibility", selection: $isPrivate) {
                        Text("Private").tag(true)
                        Text("Public").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                .formStyle(.grouped)
                if !name.isEmpty && !validName {
                    Text("Use letters, numbers, - _ and . only.").font(.caption).foregroundStyle(.red)
                }
                Text("Creates github.com/\(login)/\(name.isEmpty ? "…" : name), adds it as a remote and pushes \(model.status.branch ?? "the current branch").")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(folder.map { "This repository is in \(($0 as NSString).abbreviatingWithTildeInPath), which always uses the profile \"\(profile.name)\". That profile has no GitHub account." }
                     ?? "The profile \"\(profile.name)\" has no GitHub account yet. Connect one, or switch to a profile that has one.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if profile.gitHubLogin == nil {
                    Button("Connect GitHub…") {
                        accountsTarget = profile.id.uuidString
                        settingsTab = "accounts"
                        openSettings()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Publish") {
                        model.publishToGitHub(name: name, description: description, isPrivate: isPrivate)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validName)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = model.name.replacingOccurrences(of: " ", with: "-")
        }
    }
}

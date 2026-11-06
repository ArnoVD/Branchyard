import SwiftUI
import GitCore

/// One repository: action bar on top, then branches | diff | changes.
struct RepoView: View {
    @ObservedObject var model: RepoModel

    var body: some View {
        VStack(spacing: 0) {
            ActionBar(model: model)
            if model.opState != .none {
                OperationBanner(model: model)
            }
            if let notice = model.notice {
                Banner(text: notice, systemImage: "info.circle", tint: .blue) { model.notice = nil }
            }
            Divider()
            // branches | graph (or a diff) | files to stage + commit (or the picked commit).
            HSplitView {
                BranchesPanel(model: model)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 440, maxHeight: .infinity)
                DetailPanel(model: model)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                Group {
                    if model.showsCommitDetail {
                        CommitDetailPanel(model: model)
                    } else {
                        ChangesPanel(model: model)
                    }
                }
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 560, maxHeight: .infinity)
                .background(Color.byPanel)
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

// MARK: - Action bar

/// Top bar: `repository ▾ › branch ▾` on the left, git actions centered, Terminal on the right.
private struct ActionBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: RepoModel

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
                         help: "Pull (fast-forward if possible)") { model.pull() }
                    Menu {
                        Button("Fetch All") { model.fetch() }
                        Button("Pull") { model.pull() }
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
                    .help("Fetch or pull")
                }
                tool("Push", "arrow.up.to.line", .push, badge: model.status.ahead) { model.push() }
                tool("Branch", "arrow.triangle.branch", .branch) { model.newBranchRequest = NewBranchRequest(startPoint: nil) }
                tool("Stash", "tray.and.arrow.down", .stash) { model.stash() }
                    .disabled(model.status.isClean && model.busyAction != .stash)
                tool("Pop", "tray.and.arrow.up", .pop, badge: model.stashes.count) { model.pop() }
                    .disabled(model.stashes.isEmpty && model.busyAction != .pop)
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
                      badge: Int = 0, help: String? = nil, perform: @escaping () -> Void) -> some View {
        let running = model.busyAction != nil && (model.busyAction == action || model.busyAction == also)
        return ToolButton(title, icon, badge: running ? 0 : badge, help: help, running: running, action: perform)
            .disabled(model.busy != nil && !running)
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
    let helpText: String?
    let running: Bool
    let action: () -> Void

    init(_ title: String, _ icon: String, badge: Int = 0, help: String? = nil, running: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.badge = badge
        self.helpText = help
        self.running = running
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // Label above the icon.
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: icon)
                    .font(.system(size: 16))
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

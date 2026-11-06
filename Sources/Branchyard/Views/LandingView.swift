import SwiftUI

/// The "New Tab" page: open, clone or create a repository, or pick a recent one.
struct LandingView: View {
    @EnvironmentObject private var state: AppState
    @ViewState private var search = ""
    @FocusState private var searchFocused: Bool
    @AppStorage(SettingsView.tabKey) private var settingsTab = "appearance"

    private var repos: [LibraryRepo] {
        let all = state.recentRepos
        if search.isEmpty { return Array(all.prefix(25)) }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            repositories
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.trailing, 28)
            Divider()
            sidePanel
                .frame(width: 340, alignment: .leading)
                .padding(.leading, 24)
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.byToolbar)
        .onAppear { searchFocused = true }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Repositories").font(.system(size: 20, weight: .medium))

            HStack(spacing: 10) {
                BigButton("Open", "folder.fill") { state.promptAddRepository() }
                BigButton("Clone", "icloud.and.arrow.down.fill") { state.showClone = true }
                BigButton("Create", "plus.square.fill") { state.promptCreateRepository() }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search repositories (⌘ + Option + F)", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = repos.first { state.open(first.url) } }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(searchFocused ? Color.byAccent : Color.secondary.opacity(0.3), lineWidth: searchFocused ? 2 : 1))
            .background {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .hidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(search.isEmpty ? "Recent" : "\(repos.count) found")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.bottom, 2)
                if repos.isEmpty {
                    Text(state.library.isEmpty
                         ? "No repositories yet. Open, clone or create one above."
                         : "No repository matches “\(search)”.")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(repos) { repo in
                            RecentRow(repo: repo) { state.open(repo.url) }
                                .contextMenu {
                                    Button("Open in Tab") { state.open(repo.url) }
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([repo.url]) }
                                    Divider()
                                    Button("Remove from List") { state.removeFromLibrary(repo) }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bitbucket").font(.system(size: 18, weight: .medium))
            if BitbucketAccount.client != nil {
                Label("Signed in as \(BitbucketAccount.email)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13))
            } else {
                Text("Add your Bitbucket account to browse and clone your workspace's repositories over SSH.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsLink {
                Label(BitbucketAccount.client == nil ? "Connect Bitbucket" : "Account Settings", systemImage: "person.crop.circle")
            }
            .simultaneousGesture(TapGesture().onEnded { settingsTab = "accounts" })
            .controlSize(.large)

            Text("More").font(.system(size: 13, weight: .medium)).padding(.top, 10)
            if state.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for repositories…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Scan a folder for repositories…") { state.promptScanFolder() }
                Button("Clone from Bitbucket…") { state.showClone = true }
            }
            .buttonStyle(.link)
        }
    }
}

private struct BigButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, _ icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(hovering ? 0.22 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let repo: LibraryRepo
    let open: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Text(repo.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.byAccent)
                    .underline(hovering)
                Text((repo.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .opacity(repo.exists ? 1 : 0.45)
        .onHover { hovering = $0 }
        .help(repo.exists ? "Open \(repo.name)" : "Missing on disk")
    }
}

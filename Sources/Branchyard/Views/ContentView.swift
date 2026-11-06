import SwiftUI
import GitCore

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // No title bar: the tab strip is the top row, next to the window buttons.
        VStack(spacing: 0) {
            TabStrip()
            if let tab = state.selectedTab {
                RepoView(model: tab)
                    .id(tab.id)
            } else {
                // New Tab page, also shown when no repository tab is open.
                LandingView()
            }
            StatusBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .onAppear { DebugHooks.run(state: state) }
        .sheet(isPresented: $state.showClone) {
            CloneSheet()
                .environmentObject(state)
        }
        .alert("Branchyard", isPresented: Binding(
            get: { state.alert != nil },
            set: { if !$0 { state.alert = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(state.alert ?? "")
        }
    }
}

/// Lets you drag the window by any empty background area (there's no title bar to grab),
/// and saves a snapshot of the window when BRANCHYARD_SNAPSHOT is set (for layout checks).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if let path = ProcessInfo.processInfo.environment["BRANCHYARD_SNAPSHOT_SETTINGS"] {
                // Layout check of the Settings window, rendered on its own.
                let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                        styleMask: [.titled], backing: .buffered, defer: false)
                if let tab = ProcessInfo.processInfo.environment["BRANCHYARD_SNAPSHOT_TAB"] {
                    UserDefaults.standard.set(tab, forKey: SettingsView.tabKey)
                }
                settings.contentView = NSHostingView(rootView: ThemedRoot { SettingsView() })
                settings.orderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let frameView = settings.contentView?.superview,
                          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            if let path = ProcessInfo.processInfo.environment["BRANCHYARD_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let frameView = window.contentView?.superview,
                          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Tabs: the repositories you're working in now

/// `● ● ●  📁 | ⑂ repo-a | ⑂ repo-b × | New Tab | +            ⚙`
struct TabStrip: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 76)   // window buttons

            StripIconButton(icon: "folder", help: "Repositories (⌘T)") { state.newTab() }
                .padding(.trailing, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabSeparator(hidden: index == 0
                                     || tab.id == state.selectedTabID
                                     || state.tabs[index - 1].id == state.selectedTabID)
                        TabButton(
                            title: tab.name,
                            icon: "arrow.triangle.branch",
                            isSelected: tab.id == state.selectedTabID,
                            select: { state.selectedTabID = tab.id },
                            close: { state.closeTab(tab.id) }
                        )
                        .contextMenu {
                            Button("Close Tab") { state.closeTab(tab.id) }
                            Button("Reveal in Finder") { tab.revealInFinder() }
                            Button("Open in Terminal") { tab.openInTerminal() }
                        }
                    }
                    if state.landingOpen || state.tabs.isEmpty {
                        TabSeparator(hidden: state.tabs.isEmpty
                                     || state.selectedTab == nil
                                     || state.tabs.last?.id == state.selectedTabID)
                        TabButton(
                            title: "New Tab",
                            icon: nil,
                            isSelected: state.selectedTab == nil,
                            select: { state.newTab() },
                            close: { state.closeTab(AppState.landingID) }
                        )
                    }
                    StripIconButton(icon: "plus", help: "New tab (⌘T)") { state.newTab() }
                        .padding(.leading, 6)
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 12)
            ProfileMenu()
                .padding(.trailing, 4)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .padding(.trailing, 10)
        }
        .frame(height: 38)
        .background(Color.byTabBar)
    }
}

private struct TabSeparator: View {
    let hidden: Bool
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(hidden ? 0 : 0.14))
            .frame(width: 1, height: 16)
    }
}

private struct StripIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct TabButton: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close tab (⇧⌘W)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .frame(maxWidth: 240)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                .fill(isSelected ? Color.byToolbar : (hovering ? Color.primary.opacity(0.05) : .clear))
                .padding(.top, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

// MARK: - Profile switcher

/// Avatar + profile name at the top right. Switches who you commit and push as.
private struct ProfileMenu: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = ProfileStore.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.tabKey) private var settingsTab = "appearance"

    var body: some View {
        // What this repository actually uses: a folder rule wins over the selected profile.
        let (active, folder) = store.effective(forRepo: state.selectedTab?.repo.url.path)
        Menu {
            Section("Current profile: \(active.name)") {
                Text("Commits as \(store.signature(of: active))")
                Text(active.gitHubLogin.map { "GitHub: @\($0)" } ?? "GitHub: not connected")
                if let folder {
                    Text("Automatic: this repository is in \((folder as NSString).abbreviatingWithTildeInPath)")
                }
            }
            if store.profiles.count > 1 {
                Section(folder == nil ? "Switch profile" : "Profile for other repositories") {
                    ForEach(store.profiles) { profile in
                        Button {
                            store.select(profile.id)
                        } label: {
                            if profile.id == store.activeID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Manage Profiles…") {
                settingsTab = "profiles"
                openSettings()
            }
        } label: {
            HStack(spacing: 6) {
                ProfileAvatar(profile: active, size: 20)
                if folder != nil {
                    Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(active.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile: \(active.name) — commits as \(store.signature(of: active))")
    }
}

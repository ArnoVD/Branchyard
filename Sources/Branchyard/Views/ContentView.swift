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
            let env = ProcessInfo.processInfo.environment
            if let path = env["BRANCHYARD_SNAPSHOT"] {
                // BRANCHYARD_SNAPSHOT_DELAY: seconds (default 3). An open sheet is saved next to it as …-sheet.png.
                let delay = env["BRANCHYARD_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    func save(_ w: NSWindow, _ path: String) {
                        guard let frameView = w.contentView?.superview,
                              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    save(window, path)
                    if let sheet = window.attachedSheet {
                        save(sheet, (path as NSString).deletingPathExtension + "-sheet.png")
                    }
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
    /// The tab being dragged: how far it sits from its slot, and how far its slot has moved.
    @ViewState private var drag: (id: String, offset: CGFloat, shift: CGFloat)?
    @ViewState private var widths: [String: CGFloat] = [:]

    /// Follows the mouse; once the tab is past half of a neighbour, they swap places.
    private func dragTab(_ id: String, by dx: CGFloat) {
        var shift = drag?.id == id ? drag!.shift : 0
        while let index = state.tabs.firstIndex(where: { $0.id == id }) {
            let offset = dx - shift
            if offset > 0, index + 1 < state.tabs.count,
               let next = widths[state.tabs[index + 1].id], offset > next / 2 {
                withAnimation(.easeOut(duration: 0.15)) { state.moveTab(id, to: index + 1) }
                shift += next + 1
            } else if offset < 0, index > 0,
                      let previous = widths[state.tabs[index - 1].id], -offset > previous / 2 {
                withAnimation(.easeOut(duration: 0.15)) { state.moveTab(id, to: index - 1) }
                shift -= previous + 1
            } else {
                break
            }
        }
        drag = (id, dx - shift, shift)
    }

    private func endDrag() {
        guard let id = drag?.id else { return }
        drag = (id, drag!.offset, drag!.shift)
        withAnimation(.easeOut(duration: 0.15)) { drag = nil }
    }

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
                                     || state.tabs[index - 1].id == state.selectedTabID
                                     || drag != nil)
                        TabButton(
                            title: tab.name,
                            icon: "arrow.triangle.branch",
                            isSelected: tab.id == state.selectedTabID,
                            select: { state.selectedTabID = tab.id },
                            close: { state.closeTab(tab.id) },
                            menu: [
                                ("Close Tab", { state.closeTab(tab.id) }),
                                ("Reveal in Finder", { tab.revealInFinder() }),
                                ("Open in Terminal", { tab.openInTerminal() }),
                            ],
                            dragged: { dx in dragTab(tab.id, by: dx) },
                            dropped: { endDrag() }
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[tab.id] = $0 }
                        .offset(x: drag?.id == tab.id ? drag!.offset : 0)
                        .zIndex(drag?.id == tab.id ? 1 : 0)
                        .transaction { if drag?.id == tab.id { $0.animation = nil } }
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
                            close: { state.closeTab(AppState.landingID) },
                            menu: [("Close Tab", { state.closeTab(AppState.landingID) })]
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
    var menu: [(String, () -> Void)] = []
    var dragged: ((CGFloat) -> Void)?
    var dropped: (() -> Void)?
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
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .opacity(hovering || isSelected ? 1 : 0)
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
        // Clicks, drags, the close button and the menu go to an AppKit view: SwiftUI views count
        // as window background, so dragging a tab would move the whole window.
        .overlay(TabMouseArea(closeWidth: 8 + 16 + 4, select: select, close: close, menu: menu,
                              dragged: dragged, dropped: dropped, hover: { hovering = $0 }))
    }
}

/// Mouse handling for one tab: select on press, drag to reorder (without moving the window),
/// close button at the trailing edge, middle-click to close, right-click menu.
private struct TabMouseArea: NSViewRepresentable {
    let closeWidth: CGFloat
    let select: () -> Void
    let close: () -> Void
    let menu: [(String, () -> Void)]
    let dragged: ((CGFloat) -> Void)?
    let dropped: (() -> Void)?
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> TabMouseView {
        TabMouseView.installMonitor()
        return TabMouseView()
    }

    func updateNSView(_ view: TabMouseView, context: Context) {
        view.closeWidth = closeWidth
        view.select = select
        view.close = close
        view.menuItems = menu
        view.dragged = dragged
        view.dropped = dropped
        view.hover = hover
    }
}

final class TabMouseView: NSView {
    var closeWidth: CGFloat = 0
    var select: () -> Void = {}
    var close: () -> Void = {}
    var menuItems: [(String, () -> Void)] = []
    var dragged: ((CGFloat) -> Void)?
    var dropped: (() -> Void)?
    var hover: (Bool) -> Void = { _ in }

    private var pressX: CGFloat?
    private var dragging = false
    private var closeTip: NSView.ToolTipTag?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The top of the tab strip lies in the (hidden) title bar, where macOS starts moving the window
    /// before the tab sees the click. This catches presses on a tab before the window does.
    private static var monitor: Any?
    private static weak var pressed: TabMouseView?

    static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { route(event) } ? nil : event
        }
    }

    /// Hands the event to the tab under (or holding) the mouse; true when a tab took it.
    private static func route(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard let window = event.window, window.attachedSheet == nil,
                  let frame = window.contentView?.superview,
                  let tab = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) as? TabMouseView
            else { return false }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            pressed = tab
            tab.mouseDown(with: event)
        case .leftMouseDragged:
            guard let tab = pressed else { return false }
            tab.mouseDragged(with: event)
        default:
            guard let tab = pressed else { return false }
            pressed = nil
            tab.mouseUp(with: event)
        }
        return true
    }

    private var closeRect: NSRect { NSRect(x: bounds.maxX - closeWidth, y: 0, width: closeWidth, height: bounds.height) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        if let closeTip { removeToolTip(closeTip) }
        closeTip = addToolTip(closeRect, owner: "Close tab (⇧⌘W)" as NSString, userData: nil)
    }

    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressX = event.locationInWindow.x
        dragging = false
        if !closeRect.contains(point) { select() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX, let dragged else { return }
        let dx = event.locationInWindow.x - pressX
        if !dragging, abs(dx) < 4 { return }
        dragging = true
        dragged(dx)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressX = nil; dragging = false }
        if dragging { dropped?(); return }
        if closeRect.contains(convert(event.locationInWindow, from: nil)) { close() }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { close() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for (title, action) in menuItems {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
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

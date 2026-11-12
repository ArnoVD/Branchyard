import SwiftUI
import AppKit
import BranchyardArt
import GitCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (`swift run`) instead of from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIconArt.image(size: 512)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Git.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BranchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    init() {
        // Apply the active profile before the first git command runs.
        _ = ProfileStore.shared
    }

    var body: some Scene {
        Window("Branchyard", id: "main") {
            ThemedRoot {
                ContentView()
                    .environmentObject(state)
            }
            .frame(minWidth: 1100, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { state.newTab() }
                    .keyboardShortcut("t")
                Button("Create Repository…") { state.promptCreateRepository() }
                Divider()
                Button("Add Repository…") { state.promptAddRepository() }
                    .keyboardShortcut("o")
                Button("Clone…") { state.showClone = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Scan Folder for Repositories…") { state.promptScanFolder() }
            }
            CommandMenu("Repository") {
                Button("Refresh") { state.refreshSelected() }
                    .keyboardShortcut("r")
                Button("Fetch") { state.selectedTab?.fetch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Pull") { state.selectedTab?.pull() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Push") { state.selectedTab?.push() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Publish to GitHub…") { state.selectedTab?.showPublish = true }
                    .disabled(state.selectedTab == nil)
                Button("Create Pull Request") { state.selectedTab?.createPullRequest() }
                    .disabled(state.selectedTab == nil)
                Divider()
                Button("Search Commits") { state.selectedTab?.openSearch() }
                    .keyboardShortcut("f")
                    .disabled(state.selectedTab == nil)
                Button("Command Palette…") { state.selectedTab?.showPalette = true }
                    .keyboardShortcut("p")
                    .disabled(state.selectedTab == nil)
                Divider()
                Button("Close Tab") {
                    if let id = state.selectedTabID { state.closeTab(id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { index in
                    Button("Show Tab \(index)") { state.selectTab(at: index - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
                }
            }
        }

        Settings {
            ThemedRoot { SettingsView() }
        }
    }
}

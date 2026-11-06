import SwiftUI
import AppKit
import GitCore

/// A repository folder remembered in the sidebar.
struct LibraryRepo: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var parentFolder: String {
        ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}

/// App-wide state: the repository library (sidebar) and the open tabs.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var library: [LibraryRepo] = []
    @Published private(set) var tabs: [RepoModel] = []
    @Published var selectedTabID: String? {
        didSet {
            guard selectedTabID != oldValue else { return }
            saveTabs()
            refreshSelected()
        }
    }
    /// The "New Tab" page (open / clone / create + recent repositories).
    @Published private(set) var landingOpen = false
    static let landingID = "landing"
    /// Most recently opened repository paths, newest first.
    @Published private(set) var recent: [String] = []
    @Published var showClone = false
    @Published var alert: String?
    @Published var scanning = false

    private let defaults = UserDefaults.standard
    private var autoFetchTimer: Timer?

    init() {
        library = (defaults.stringArray(forKey: "library") ?? []).map(LibraryRepo.init(path:))
        recent = defaults.stringArray(forKey: "recent") ?? []
        for path in defaults.stringArray(forKey: "openTabs") ?? [] where FileManager.default.fileExists(atPath: path) {
            tabs.append(RepoModel(url: URL(fileURLWithPath: path, isDirectory: true)))
        }
        let saved = defaults.string(forKey: "selectedTab")
        if saved == Self.landingID {
            landingOpen = true
            selectedTabID = Self.landingID
        } else {
            selectedTabID = tabs.contains { $0.id == saved } ? saved : tabs.first?.id
        }

        let restored = tabs
        Task { for tab in restored { await tab.refresh() } }

        // Auto-fetch: every minute, fetch the tabs whose last fetch is older than the setting.
        autoFetchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoFetchDue() }
        }

        // Pick up changes made in Terminal / an editor when you switch back to the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSelected() }
        }
    }

    var selectedTab: RepoModel? { tabs.first { $0.id == selectedTabID } }

    private func autoFetchDue() {
        let minutes = defaults.object(forKey: AutoFetch.minutesKey) as? Int ?? AutoFetch.defaultMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        for tab in tabs where (tab.lastFetched ?? .distantPast) < cutoff {
            tab.autoFetch()
        }
    }

    var defaultCloneFolder: URL {
        get {
            if let saved = defaults.string(forKey: "cloneFolder") { return URL(fileURLWithPath: saved, isDirectory: true) }
            let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Development")
            return FileManager.default.fileExists(atPath: dev.path) ? dev : FileManager.default.homeDirectoryForCurrentUser
        }
        set { defaults.set(newValue.path, forKey: "cloneFolder") }
    }

    // MARK: tabs

    func open(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            alert = "\(path) no longer exists. Remove it from the list or clone it again."
            return
        }
        addToLibrary([url])
        if !tabs.contains(where: { $0.id == path }) {
            tabs.append(RepoModel(url: URL(fileURLWithPath: path, isDirectory: true)))
        }
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recent = Array(recent.prefix(30))
        defaults.set(recent, forKey: "recent")
        // Picking a repo on the New Tab page turns that page into the repo's tab.
        if selectedTabID == Self.landingID { landingOpen = false }
        selectedTabID = path
        saveTabs()
    }

    /// Repositories for the New Tab page: recently opened first, then the rest of the library.
    var recentRepos: [LibraryRepo] {
        let byPath = Dictionary(library.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let first = recent.compactMap { byPath[$0] }
        let seen = Set(first.map(\.path))
        return first + library.filter { !seen.contains($0.path) }
    }

    func newTab() {
        landingOpen = true
        selectedTabID = Self.landingID
    }

    func closeTab(_ id: String) {
        if id == Self.landingID {
            landingOpen = false
            if selectedTabID == id { selectedTabID = tabs.last?.id }
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? (landingOpen ? Self.landingID : nil) : tabs[min(index, tabs.count - 1)].id
        }
        saveTabs()
    }

    func selectTab(at index: Int) {
        if tabs.indices.contains(index) {
            selectedTabID = tabs[index].id
        } else if index == tabs.count, landingOpen {
            selectedTabID = Self.landingID
        }
    }

    func refreshSelected() {
        guard let tab = selectedTab else { return }
        Task { await tab.refresh() }
    }

    private func saveTabs() {
        defaults.set(tabs.map(\.id), forKey: "openTabs")
        defaults.set(selectedTabID, forKey: "selectedTab")
    }

    // MARK: library

    func addToLibrary(_ urls: [URL]) {
        var paths = Set(library.map(\.path))
        for url in urls { paths.insert(url.standardizedFileURL.path) }
        library = paths.map(LibraryRepo.init(path:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaults.set(library.map(\.path), forKey: "library")
    }

    func removeFromLibrary(_ repo: LibraryRepo) {
        library.removeAll { $0.id == repo.id }
        defaults.set(library.map(\.path), forKey: "library")
    }

    func promptAddRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more git repository folders"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            var notRepos: [String] = []
            for url in urls {
                if let root = await Repository.root(containing: url) {
                    open(root)
                } else {
                    notRepos.append(url.lastPathComponent)
                }
            }
            if !notRepos.isEmpty {
                alert = "Not a git repository: \(notRepos.joined(separator: ", ")). Use “Scan Folder…” to find repositories inside a folder."
            }
        }
    }

    func promptCreateRepository() {
        let panel = NSSavePanel()
        panel.title = "Create Repository"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Repository name:"
        panel.nameFieldStringValue = "new-repository"
        panel.message = "A new folder with an empty git repository (branch main)"
        panel.directoryURL = defaultCloneFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                open(try await Repository.create(at: url))
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func promptScanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        panel.message = "Find all git repositories inside this folder (4 levels deep)"
        panel.directoryURL = defaultCloneFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { Repository.scan(folder: folder) }.value
            let before = library.count
            addToLibrary(found)
            scanning = false
            alert = "Found \(found.count) repositories in \(folder.lastPathComponent) (\(library.count - before) new)."
        }
    }
}

enum AutoFetch {
    static let minutesKey = "fetch.autoMinutes"
    static let defaultMinutes = 5
}

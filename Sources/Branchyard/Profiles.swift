import SwiftUI
import AppKit
import Security
import GitCore

/// Who you commit as, and which GitHub account you push with.
/// Empty author fields mean "use my git config", so a work profile can leave everything as it is.
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var authorName = ""
    var authorEmail = ""
    /// Set once a GitHub token is saved for this profile (the token itself lives in the Keychain).
    var gitHubLogin: String?
    var gitHubNoReplyEmail: String?
    /// Repositories in these folders always use this profile, whichever one is active.
    var folders: [String] = []

    init(name: String) { self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        authorEmail = try c.decodeIfPresent(String.self, forKey: .authorEmail) ?? ""
        gitHubLogin = try c.decodeIfPresent(String.self, forKey: .gitHubLogin)
        gitHubNoReplyEmail = try c.decodeIfPresent(String.self, forKey: .gitHubNoReplyEmail)
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
    }
}

/// Profiles, the active one, and applying it to every git command (see `GitIdentity`).
/// Nothing is written to ~/.gitconfig.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeID: UUID
    /// user.name / user.email from your global git config, for "use git config" profiles.
    @Published private(set) var gitConfigName = ""
    @Published private(set) var gitConfigEmail = ""

    private let defaults = UserDefaults.standard
    private var tokens: [UUID: String] = [:]

    private init() {
        let loaded: [Profile]
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let saved = try? JSONDecoder().decode([Profile].self, from: data), !saved.isEmpty {
            loaded = saved
        } else {
            loaded = [Profile(name: "Default")]
        }
        let savedID = UserDefaults.standard.string(forKey: "activeProfileID").flatMap(UUID.init)
        activeID = loaded.first { $0.id == savedID }?.id ?? loaded[0].id
        profiles = loaded
        for profile in profiles where profile.gitHubLogin != nil {
            tokens[profile.id] = GitHubKeychain.load(profile.id)
        }
        // Keep the first Default profile's id stable across launches.
        if UserDefaults.standard.data(forKey: "profiles") == nil { save() }
        apply()
        Task { await loadGitConfig() }
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }

    /// The profile a repository at `path` uses, and the folder rule that chose it (nil = the active profile).
    func effective(forRepo path: String?) -> (profile: Profile, folder: String?) {
        guard let path else { return (active, nil) }
        let pairs = profiles.flatMap { p in p.folders.map { (p, $0) } }
        guard let i = GitIdentity.matchingFolder(path, in: pairs.map(\.1)) else { return (active, nil) }
        return (pairs[i].0, pairs[i].1)
    }

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        defaults.set(id.uuidString, forKey: "activeProfileID")
        apply()
    }

    @discardableResult
    func add() -> Profile {
        let profile = Profile(name: profiles.isEmpty ? "Default" : "Profile \(profiles.count + 1)")
        profiles.append(profile)
        save()
        return profile
    }

    func update(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save()
        apply()
    }

    func delete(_ id: UUID) {
        guard profiles.count > 1 else { return }
        GitHubKeychain.delete(id)
        tokens[id] = nil
        profiles.removeAll { $0.id == id }
        save()
        if id == activeID { select(profiles[0].id) } else { apply() }
    }

    // MARK: GitHub

    func gitHubToken(for id: UUID) -> String? { tokens[id] }

    /// Checks the token with GitHub, then keeps it in the Keychain.
    func connectGitHub(_ id: UUID, token: String) async throws -> GitHubUser {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try await GitHubClient(token: token).user()
        GitHubKeychain.save(token, for: id)
        tokens[id] = token
        if var profile = profile(id) {
            profile.gitHubLogin = user.login
            profile.gitHubNoReplyEmail = user.noReplyEmail
            if profile.authorName.isEmpty, let name = user.name { profile.authorName = name }
            update(profile)
        }
        return user
    }

    func disconnectGitHub(_ id: UUID) {
        GitHubKeychain.delete(id)
        tokens[id] = nil
        if var profile = profile(id) {
            profile.gitHubLogin = nil
            profile.gitHubNoReplyEmail = nil
            update(profile)
        }
    }

    // MARK: display

    /// "Name <email>" this profile commits as.
    func signature(of profile: Profile) -> String {
        let name = profile.authorName.isEmpty ? gitConfigName : profile.authorName
        let email = profile.authorEmail.isEmpty ? gitConfigEmail : profile.authorEmail
        if name.isEmpty && email.isEmpty { return "Not set (git config has no user.name)" }
        return email.isEmpty ? name : "\(name) <\(email)>"
    }

    // MARK: private

    private func apply() {
        func env(_ p: Profile) -> [String: String] {
            GitIdentity.environment(authorName: p.authorName, authorEmail: p.authorEmail, gitHubToken: tokens[p.id])
        }
        GitIdentity.environment = env(active)
        GitIdentity.rules = profiles.flatMap { p in p.folders.map { GitIdentity.FolderRule(folder: $0, environment: env(p)) } }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "profiles") }
    }

    private func loadGitConfig() async {
        let git = Git(directory: FileManager.default.homeDirectoryForCurrentUser)
        // Read without the profile override (config values don't depend on env author vars).
        let name = try? await git.run(["config", "--global", "user.name"], allowFailure: true)
        let email = try? await git.run(["config", "--global", "user.email"], allowFailure: true)
        gitConfigName = name?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        gitConfigEmail = email?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// GitHub tokens, one Keychain item per profile.
enum GitHubKeychain {
    private static let service = "Branchyard.github"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func save(_ token: String, for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
        var add = query(id)
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

// MARK: - Avatar

/// Round initials badge, coloured per profile.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 22

    private static let colors: [Color] = [
        Color(red: 0.52, green: 0.85, blue: 0.80), Color(red: 0.98, green: 0.60, blue: 0.40),
        Color(red: 0.67, green: 0.62, blue: 0.95), Color(red: 0.99, green: 0.85, blue: 0.40),
        Color(red: 0.98, green: 0.45, blue: 0.55), Color(red: 0.55, green: 0.80, blue: 0.45),
    ]

    var body: some View {
        let words = profile.name.split(separator: " ")
        let initials = (words.count >= 2 ? [words[0], words[words.count - 1]] : Array(words.prefix(1)))
            .compactMap { $0.first.map(String.init) }.joined().uppercased()
        let index = profile.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colors.count
        ZStack {
            Circle().fill(Self.colors[index])
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Settings ▸ Profiles

struct ProfilesSettings: View {
    @ObservedObject private var store = ProfileStore.shared
    @ViewState private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.profiles) { profile in
                        HStack(spacing: 8) {
                            ProfileAvatar(profile: profile, size: 20)
                            Text(profile.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if profile.id == store.activeID {
                                Text("Active").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 0) {
                    Button { selection = store.add().id } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add profile")
                    Button {
                        if let id = selection { store.delete(id); selection = store.activeID }
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil || store.profiles.count < 2)
                        .help("Delete profile")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .frame(width: 190)

            if let id = selection ?? Optional(store.activeID), store.profile(id) != nil {
                ProfileEditor(id: id).id(id)
            }
        }
        .padding(20)
        .frame(height: 460)
        .onAppear { if selection == nil { selection = store.activeID } }
    }
}

private struct ProfileEditor: View {
    let id: UUID
    @ObservedObject private var store = ProfileStore.shared
    @AppStorage(SettingsView.tabKey) private var settingsTab = "profiles"
    @AppStorage(AccountsSettings.profileKey) private var accountsTarget = ""

    private var profile: Profile { store.profile(id) ?? Profile(name: "") }

    private func field(_ key: WritableKeyPath<Profile, String>) -> Binding<String> {
        Binding(get: { profile[keyPath: key] },
                set: { var p = profile; p[keyPath: key] = $0; store.update(p) })
    }

    var body: some View {
        Form {
            Section {
                row("Profile name") {
                    TextField("", text: field(\.name), prompt: Text("e.g. Work or Personal"))
                }
                row("Author name") {
                    TextField("", text: field(\.authorName), prompt: Text("Name on your commits"))
                }
                row("Author email") {
                    TextField("", text: field(\.authorEmail), prompt: Text("you@example.com"))
                }
                let canCopy = profile.authorName.isEmpty && profile.authorEmail.isEmpty && !store.gitConfigEmail.isEmpty
                let canNoReply = profile.gitHubNoReplyEmail.map { $0 != profile.authorEmail } ?? false
                if canCopy || canNoReply {
                HStack(spacing: 12) {
                    if canCopy {
                        Button("Copy from git config") {
                            var p = profile
                            p.authorName = store.gitConfigName
                            p.authorEmail = store.gitConfigEmail
                            store.update(p)
                        }
                    }
                    if let noReply = profile.gitHubNoReplyEmail, profile.authorEmail != noReply {
                        Button("Use GitHub private email") {
                            var p = profile; p.authorEmail = noReply; store.update(p)
                        }
                        .help(noReply)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                }
            } header: {
                HStack {
                    Text("Commit signature")
                    Spacer()
                    if id == store.activeID {
                        Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(Color.byAccent).font(.caption)
                    } else {
                        Button("Use This Profile") { store.select(id) }.controlSize(.small)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commits as **\(store.signature(of: profile))**")
                    if profile.authorName.isEmpty || profile.authorEmail.isEmpty {
                        Text("Empty fields fall back to your git config.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ForEach(profile.folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button {
                            var p = profile; p.folders.removeAll { $0 == folder }; store.update(p)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove folder")
                    }
                }
                Button("Add Folder…") { addFolder() }
            } header: {
                Text("Use automatically for repositories in")
            } footer: {
                Text("Repositories in these folders always commit and push as this profile, whichever profile is selected. Other repositories use the selected profile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                HStack {
                    if let login = profile.gitHubLogin {
                        Label("Connected as @\(login)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(profile.gitHubLogin == nil ? "Connect GitHub…" : "Manage in Accounts…") {
                        accountsTarget = id.uuidString
                        settingsTab = "accounts"
                    }
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Repositories that use this profile push, pull and publish with this GitHub account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        FormRow(label, content: content)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Repositories in this folder will use the profile \"\(profile.name)\""
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Development")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var p = profile
        if !p.folders.contains(url.path) { p.folders.append(url.path) }
        store.update(p)
    }
}

/// Label on the left, an obviously editable text box on the right.
/// (Grouped forms otherwise draw text fields borderless and right-aligned, which reads as plain text.)
struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
            content
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}

// MARK: - Settings ▸ Accounts

/// GitHub and Bitbucket in one place. GitHub accounts belong to a profile,
/// so work and personal repositories never push with the wrong account.
struct AccountsSettings: View {
    static let profileKey = "accountsGitHubProfile"

    @ObservedObject private var store = ProfileStore.shared
    @AppStorage(AccountsSettings.profileKey) private var target = ""
    @ViewState private var token = ""
    @ViewState private var connecting = false
    @ViewState private var error: String?

    private var unconnected: [Profile] { store.profiles.filter { $0.gitHubLogin == nil } }

    /// The profile the token will be saved to: the one picked, else a "Personal" one, else one without folder rules.
    private var targetID: UUID? {
        if let id = UUID(uuidString: target), unconnected.contains(where: { $0.id == id }) { return id }
        return (unconnected.first { $0.name.localizedCaseInsensitiveContains("personal") }
                ?? unconnected.first { $0.folders.isEmpty }
                ?? unconnected.first)?.id
    }

    var body: some View {
        Form {
            Section {
                ForEach(store.profiles.filter { $0.gitHubLogin != nil }) { p in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("@\(p.gitHubLogin ?? "")").fontWeight(.medium)
                        Text("for profile").foregroundStyle(.secondary)
                        ProfileAvatar(profile: p, size: 16)
                        Text(p.name)
                        Spacer()
                        Button("Disconnect") { store.disconnectGitHub(p.id) }
                    }
                }
                if let targetID {
                    FormRow("Profile") {
                        HStack {
                            Picker("Profile", selection: Binding(get: { targetID }, set: { target = $0.uuidString })) {
                                ForEach(unconnected) { p in Text(p.name).tag(p.id) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                        }
                    }
                    FormRow("Access token") {
                        SecureField("Access token", text: $token, prompt: Text("Paste your GitHub token here"))
                            .onSubmit { connect(targetID) }
                    }
                    HStack {
                        Link("Create a token on GitHub…",
                             destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Branchyard")!)
                            .font(.caption)
                        Spacer()
                        if connecting { ProgressView().controlSize(.small) }
                        Button("Connect") { connect(targetID) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Every profile has a GitHub account. Disconnect one to connect another.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Classic token: tick the \"repo\" scope. Fine-grained token: All repositories, with Administration and Contents set to Read and write. Stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            BitbucketSections(onSaved: {})
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }

    private func connect(_ id: UUID) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !connecting else { return }
        connecting = true
        error = nil
        Task {
            do {
                _ = try await store.connectGitHub(id, token: token)
                token = ""
                target = ""
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

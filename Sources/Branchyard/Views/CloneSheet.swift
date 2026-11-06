import SwiftUI
import Security
import GitCore

// MARK: - Keychain + saved account

enum Keychain {
    private static let service = "Branchyard.bitbucket"

    static func save(_ secret: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecAttrAccount as String] = account
        add[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}

enum BitbucketAccount {
    static var email: String {
        get { UserDefaults.standard.string(forKey: "bitbucketEmail") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bitbucketEmail") }
    }
    static var workspace: String {
        get { UserDefaults.standard.string(forKey: "bitbucketWorkspace") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bitbucketWorkspace") }
    }
    static var client: BitbucketClient? {
        guard !email.isEmpty, let token = Keychain.load(), !token.isEmpty else { return nil }
        return BitbucketClient(email: email, apiToken: token)
    }
}

// MARK: - Account form (also the Settings window)

struct BitbucketAccountForm: View {
    var onSaved: () -> Void

    var body: some View {
        Form { BitbucketSections(onSaved: onSaved) }
            .formStyle(.grouped)
    }
}

/// The Bitbucket account and SSH sections, for embedding in a grouped Form.
struct BitbucketSections: View {
    var onSaved: () -> Void
    @ViewState private var email = BitbucketAccount.email
    @ViewState private var token = ""
    @ViewState private var workspace = BitbucketAccount.workspace
    @ViewState private var hasToken = Keychain.load() != nil
    @ViewState private var sshResult: String?
    @ViewState private var testingSSH = false

    var body: some View {
        Group {
            Section {
                FormRow("Atlassian email") {
                    TextField("Atlassian email", text: $email, prompt: Text("you@company.com"))
                }
                FormRow("API token") {
                    SecureField("API token", text: $token,
                                prompt: Text(hasToken ? "Saved. Leave empty to keep it" : "Paste your Atlassian API token here"))
                }
                FormRow("Workspace ID") {
                    TextField("Workspace ID", text: $workspace, prompt: Text("Optional, e.g. mycompany"))
                }
                HStack {
                    if hasToken {
                        Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    if hasToken {
                        Button("Sign Out", role: .destructive) {
                            Keychain.delete()
                            hasToken = false
                        }
                    }
                    Button("Save") { save() }
                        .disabled(email.isEmpty || (!hasToken && token.isEmpty))
                }
            } header: {
                Text("Bitbucket")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create an API token at id.atlassian.com → Security → API tokens → “Create API token with scopes”, app Bitbucket, scope read:repository:bitbucket (and read:workspace:bitbucket). The token is stored in your Keychain and only used to list repositories.")
                    Link("Open Atlassian API tokens", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                HStack {
                    Button("Test SSH to bitbucket.org") { testSSH() }
                        .disabled(testingSSH)
                    if testingSSH { ProgressView().controlSize(.small) }
                }
                if let sshResult {
                    Text(sshResult).font(.caption.monospaced()).textSelection(.enabled)
                }
            } header: {
                Text("SSH (used for clone, pull and push)")
            } footer: {
                Text("Uses your ~/.ssh keys. Add your public key in Bitbucket → Personal settings → SSH keys. For a key with a passphrase, add it once with: ssh-add --apple-use-keychain ~/.ssh/id_ed25519")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        BitbucketAccount.email = email.trimmingCharacters(in: .whitespaces)
        BitbucketAccount.workspace = workspace.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            Keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: BitbucketAccount.email)
            hasToken = true
            token = ""
        }
        onSaved()
    }

    private func testSSH() {
        testingSSH = true
        sshResult = nil
        Task {
            let output = await Task.detached { () -> String in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                                     "-o", "ConnectTimeout=10", "git@bitbucket.org"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { return error.localizedDescription }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }.value
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("authenticated via") || trimmed.contains("logged in as") {
                sshResult = "✓ " + trimmed
            } else if trimmed.contains("Permission denied") {
                sshResult = "✗ Bitbucket refused your key. Add your public key to Bitbucket, or run ssh-add.\n\n" + trimmed
            } else {
                sshResult = trimmed.isEmpty ? "No response." : trimmed
            }
            testingSSH = false
        }
    }
}

// MARK: - Clone sheet

struct CloneSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case bitbucket = "Bitbucket", url = "SSH URL"
        var id: String { rawValue }
    }

    @ViewState private var mode: Mode = .bitbucket
    @ViewState private var repos: [BitbucketRepo] = []
    @ViewState private var loading = false
    @ViewState private var loadError: String?
    @ViewState private var filter = ""
    @ViewState private var selection: Set<String> = []
    @ViewState private var showAccount = BitbucketAccount.client == nil
    @ViewState private var manualURL = ""
    @ViewState private var folder: URL?
    @ViewState private var cloning = false
    @ViewState private var progress: String?
    @ViewState private var failures: [String] = []

    private var parentFolder: URL { folder ?? state.defaultCloneFolder }

    private var localNames: Set<String> { Set(state.library.map(\.name)) }

    private var filtered: [BitbucketRepo] {
        filter.isEmpty ? repos : repos.filter {
            $0.fullName.localizedCaseInsensitiveContains(filter)
                || ($0.description ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clone Repositories").font(.title2.bold())
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if mode == .bitbucket {
                bitbucketSection
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("git@bitbucket.org:mycompany/my-repo.git", text: $manualURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Any SSH or HTTPS clone URL. Works for Bitbucket Server / Data Center too (e.g. ssh://git@bitbucket.mycompany.com:7999/proj/repo.git).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()
            HStack {
                Text("Clone into:").foregroundStyle(.secondary)
                Text((parentFolder.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                Button("Change…") { chooseFolder() }
                Spacer()
                if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !failures.isEmpty {
                ScrollView {
                    Text(failures.joined(separator: "\n\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            HStack {
                Spacer()
                Button(cloning ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(cloneButtonTitle) { startClone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(cloning || cloneTargets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
        .task { if BitbucketAccount.client != nil && repos.isEmpty { await loadRepos() } }
    }

    @ViewBuilder
    private var bitbucketSection: some View {
        if showAccount {
            ScrollView {
                BitbucketAccountForm {
                    showAccount = false
                    Task { await loadRepos() }
                }
            }
        } else {
            HStack {
                TextField("Search repositories", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await loadRepos() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload list")
                Button("Account…") { showAccount = true }
            }
            if let loadError {
                Text(loadError).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            List(filtered, selection: $selection) { repo in
                HStack {
                    Image(systemName: repo.isPrivate == false ? "globe" : "lock")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.fullName)
                        if let d = repo.description, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if localNames.contains(Repository.folderName(forRemote: repo.sshURL ?? repo.name)) {
                        Text("on disk").font(.caption).foregroundStyle(.green)
                    }
                    if let updated = repo.updatedOn?.prefix(10) {
                        Text(updated).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(repo.id)
            }
            .overlay {
                if loading {
                    ProgressView("Loading repositories…")
                } else if repos.isEmpty && loadError == nil {
                    ContentUnavailableView("No repositories", systemImage: "tray")
                }
            }
            Text("\(repos.count) repositories · select several with ⌘-click or ⇧-click")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cloneTargets: [String] {
        switch mode {
        case .url:
            let url = manualURL.trimmingCharacters(in: .whitespaces)
            return url.isEmpty ? [] : [url]
        case .bitbucket:
            return repos.filter { selection.contains($0.id) }.compactMap(\.sshURL)
        }
    }

    private var cloneButtonTitle: String {
        cloneTargets.count > 1 ? "Clone \(cloneTargets.count) Repositories" : "Clone"
    }

    private func loadRepos() async {
        guard let client = BitbucketAccount.client else { showAccount = true; return }
        loading = true
        loadError = nil
        do {
            let ws = BitbucketAccount.workspace
            repos = try await client.repositories(workspace: ws.isEmpty ? nil : ws)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = parentFolder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            state.defaultCloneFolder = url
        }
    }

    private func startClone() {
        let targets = cloneTargets
        let parent = parentFolder
        cloning = true
        failures = []
        Task {
            var cloned: [URL] = []
            for (index, remote) in targets.enumerated() {
                let name = Repository.folderName(forRemote: remote)
                progress = "Cloning \(name) (\(index + 1)/\(targets.count))…"
                if FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path) {
                    failures.append("\(name): folder already exists in \(parent.lastPathComponent). Skipped.")
                    continue
                }
                do {
                    cloned.append(try await Repository.clone(remoteURL: remote, into: parent, folderName: name))
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }
            progress = nil
            cloning = false
            state.addToLibrary(cloned)
            if let first = cloned.first { state.open(first) }
            if failures.isEmpty { dismiss() }
        }
    }
}

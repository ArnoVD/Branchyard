import SwiftUI
import GitCore

/// Loose check of git's ref name rules (`git check-ref-format`), for instant feedback.
func isValidRefName(_ name: String) -> Bool {
    guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
          !name.hasSuffix("."), !name.hasSuffix(".lock"), name != "@",
          !name.contains(".."), !name.contains("//"), !name.contains("@{") else { return false }
    let banned = Set(" ~^:?*[\\")
    return !name.contains { banned.contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }
}

/// Shared layout of the small name-entry sheets: title, explanation, fields, error, buttons.
private struct RefSheet<Fields: View>: View {
    let title: String
    let subtitle: String
    let error: String?
    let actionTitle: String
    let canSubmit: Bool
    let submit: () -> Void
    @ViewBuilder let fields: () -> Fields
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            fields()
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func go() {
        guard canSubmit else { return }
        submit()
        dismiss()
    }
}

// MARK: - Tag

struct NewTagSheet: View {
    @ObservedObject var model: RepoModel
    let request: NewTagRequest
    @ViewState private var name = ""
    @ViewState private var message = ""
    @AppStorage("tag.pushAfter") private var pushAfter = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var error: String? {
        if model.tags.contains(where: { $0.name == trimmed }) { return "A tag with that name already exists." }
        if !trimmed.isEmpty && !isValidRefName(trimmed) { return "Not a valid tag name (no spaces, ~ ^ : ? * [ or ..)." }
        return nil
    }
    private var remote: String? { model.remotes.contains("origin") ? "origin" : model.remotes.first }

    var body: some View {
        RefSheet(title: "New Tag",
                 subtitle: "On \(request.sha.prefix(7)) · \(request.subject)",
                 error: error, actionTitle: "Create Tag",
                 canSubmit: !trimmed.isEmpty && error == nil, submit: create) {
            TextField("Name, e.g. v1.2.0", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Message", text: $message, prompt: Text("Message (optional, makes an annotated tag)"))
                .textFieldStyle(.roundedBorder)
            if let remote {
                Toggle("Push to \(remote) after creating", isOn: $pushAfter)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func create() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        model.createTag(trimmed, at: request.sha, message: text.isEmpty ? nil : text,
                        pushTo: pushAfter ? remote : nil)
    }
}

// MARK: - Rename branch

struct RenameBranchSheet: View {
    @ObservedObject var model: RepoModel
    let branch: Branch
    @ViewState private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var error: String? {
        if trimmed != branch.name && model.localBranches.contains(where: { $0.name == trimmed }) {
            return "A branch with that name already exists."
        }
        if !trimmed.isEmpty && !isValidRefName(trimmed) { return "Not a valid branch name." }
        return nil
    }

    var body: some View {
        RefSheet(title: "Rename Branch",
                 subtitle: branch.upstream == nil
                    ? "Rename \(branch.name)."
                    : "Rename \(branch.name). It keeps tracking \(branch.upstream!); the remote branch keeps its name.",
                 error: error, actionTitle: "Rename",
                 canSubmit: !trimmed.isEmpty && trimmed != branch.name && error == nil,
                 submit: { model.renameBranch(branch, to: trimmed) }) {
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onAppear { name = branch.name }
        }
    }
}

// MARK: - Upstream

struct UpstreamSheet: View {
    @ObservedObject var model: RepoModel
    let branch: Branch
    /// "" = no upstream.
    @ViewState private var choice = ""

    private var remoteBranches: [String] {
        model.branches.filter { $0.isRemote && $0.nameWithoutRemote != "HEAD" }.map(\.name)
    }

    var body: some View {
        RefSheet(title: "Set Upstream",
                 subtitle: "The remote branch \(branch.name) pulls from and pushes to.",
                 error: remoteBranches.isEmpty ? "No remote branches yet. Push the branch to create one." : nil,
                 actionTitle: "Save",
                 canSubmit: choice != (branch.upstream ?? ""),
                 submit: { model.setUpstream(of: branch, to: choice.isEmpty ? nil : choice) }) {
            Picker("Upstream", selection: $choice) {
                Text("None").tag("")
                Divider()
                ForEach(remoteBranches, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .onAppear {
                let sameName = remoteBranches.first { $0.hasSuffix("/" + branch.name) }
                choice = branch.upstream ?? sameName ?? ""
            }
        }
    }
}

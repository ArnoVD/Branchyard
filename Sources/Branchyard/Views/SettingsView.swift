import SwiftUI

/// Branchyard ▸ Settings… (⌘,)
struct SettingsView: View {
    static let tabKey = "settingsTab"
    @AppStorage(SettingsView.tabKey) private var tab = "appearance"

    var body: some View {
        TabView(selection: $tab) {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag("appearance")
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "textformat") }
                .tag("editor")
            ProfilesSettings()
                .tabItem { Label("Profiles", systemImage: "person.2") }
                .tag("profiles")
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag("accounts")
        }
        .frame(width: 620)
        .onAppear { if tab == "bitbucket" { tab = "accounts" } }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(Theme.key) private var themeID = Theme.system.id

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme").font(.headline)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Theme.all) { theme in
                        ThemeCard(theme: theme, selected: theme.id == themeID) { themeID = theme.id }
                    }
                }
            }
            .padding(20)
        }
        .frame(height: 460)
    }
}

private struct ThemeCard: View {
    let theme: Theme
    let selected: Bool
    let pick: () -> Void

    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                preview
                    .environment(\.colorScheme, theme.scheme ?? systemScheme)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? Color.byAccent : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                HStack(spacing: 4) {
                    Text(theme.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.byAccent)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A tiny window: tab strip, toolbar with accent, sidebar, and a diff with a removed and added line.
    private var preview: some View {
        let accent = theme.accent ?? .accentColor
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(theme.toolbar).frame(width: 34, height: 8)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.15)).frame(width: 26, height: 6)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 13, alignment: .bottom)
            .background(theme.tabBar)

            HStack(spacing: 5) {
                ForEach(0..<4) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.35)).frame(width: 10, height: 6)
                }
                Spacer()
                Circle().fill(accent).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 6)
            .frame(height: 15)
            .background(theme.toolbar)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    bar(accent, width: 26)
                    bar(Color.primary.opacity(0.3), width: 30)
                    bar(Color.primary.opacity(0.3), width: 22)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .background(theme.sidebar)

                VStack(alignment: .leading, spacing: 0) {
                    line(Color.primary.opacity(0.3), width: 60, background: .clear)
                    line(Color.primary.opacity(0.4), width: 74, background: theme.removed)
                    line(Color.primary.opacity(0.4), width: 82, background: theme.added)
                    line(Color.primary.opacity(0.3), width: 50, background: .clear)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.pane)
            }
        }
    }

    private func bar(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: width, height: 4)
    }

    private func line(_ color: Color, width: CGFloat, background: Color) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: width, height: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 11)
        .background(background)
    }
}

// MARK: - Editor

private struct EditorSettings: View {
    @AppStorage(EditorPrefs.fontKey) private var family = ""
    @AppStorage(EditorPrefs.sizeKey) private var size = 12.0
    @AppStorage(EditorPrefs.tabKey) private var tabSize = 4
    @AppStorage(EditorPrefs.lineNumbersKey) private var lineNumbers = true
    @AppStorage(EditorPrefs.wrapKey) private var wordWrap = false
    @AppStorage(EditorPrefs.monoOnlyKey) private var monoOnly = true
    @AppStorage(SyntaxPalette.key) private var syntaxTheme = ""
    @AppStorage(Theme.key) private var themeID = Theme.system.id

    private var families: [String] {
        var list = monoOnly ? EditorPrefs.monospaceFamilies : EditorPrefs.allFamilies
        if !family.isEmpty, !list.contains(family) { list.insert(family, at: 0) }
        return list
    }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font", selection: $family) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Show only monospace fonts", isOn: $monoOnly)
                Stepper(value: $size, in: 9...28, step: 1) {
                    LabeledContent("Font size", value: "\(Int(size)) pt")
                }
            }
            Section("Code colors") {
                Picker("Highlighting", selection: $syntaxTheme) {
                    ForEach(SyntaxPalette.choices, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            Section("Diff") {
                Stepper(value: $tabSize, in: 1...8) {
                    LabeledContent("Tab size", value: tabSize == 1 ? "1 space" : "\(tabSize) spaces")
                }
                Toggle("Show line numbers", isOn: $lineNumbers)
                Toggle("Word wrap", isOn: $wordWrap)
            }
            Section("Preview") {
                preview
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }

    private var preview: some View {
        let font = EditorPrefs.font(family: family, size: size)
        let palette = SyntaxPalette.named(syntaxTheme)
        let java = SyntaxLanguage.forPath("Preview.java")
        let rows: [(String, String, Color)] = [
            ("12", "    // Builds the greeting", .clear),
            ("13", "    public static String greet(String name, int count) {", .clear),
            ("14", "        return \"Hi \" + name;", DiffColors.removed),
            ("14", "        return String.format(\"Hello, %s!\", name) + MAX_COUNT;", DiffColors.added),
            ("15", "    }", .clear),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    if lineNumbers {
                        Text(row.0).foregroundStyle(.tertiary).frame(width: max(34, size * 3.4), alignment: .trailing).padding(.trailing, 8)
                    }
                    Text(SyntaxHighlighter.highlight(
                        row.1.replacingOccurrences(of: "    ", with: String(repeating: " ", count: tabSize)),
                        language: java, palette: palette))
                    Spacer(minLength: 0)
                }
                .font(font)
                .padding(.vertical, 1)
                .background(row.2)
            }
        }
        .padding(.vertical, 4)
        .background(Color.byPane)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

import SwiftUI
import AppKit

// MARK: - Themes

/// A color theme: window chrome, panes, accent and diff colors. Picked in Settings › Appearance.
struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    /// Forces light or dark; nil follows macOS.
    let scheme: ColorScheme?
    let tabBar: Color
    let toolbar: Color
    let sidebar: Color
    /// Side panels and headers.
    let panel: Color
    /// Graph and diff background.
    let pane: Color
    /// nil uses the macOS accent color.
    let accent: Color?
    let added: Color
    let removed: Color
    /// Graph lane colors; nil uses the default palette.
    var lanes: [Color]? = nil
    /// Code colors in diffs; nil uses the standard palette.
    var syntax: SyntaxPalette? = nil

    static let key = "theme"

    static var current: Theme {
        named(UserDefaults.standard.string(forKey: key) ?? "")
    }

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? system
    }

    var appearance: NSAppearance? {
        switch scheme {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    static let system = Theme(
        id: "system", name: "System", scheme: nil,
        tabBar: .adaptive(light: NSColor(white: 0.85, alpha: 1), dark: .hex(0x191A1E)),
        toolbar: .adaptive(light: NSColor(white: 0.97, alpha: 1), dark: .hex(0x2A2B30)),
        sidebar: .adaptive(light: NSColor(white: 0.935, alpha: 1), dark: .hex(0x202125)),
        panel: Color(nsColor: .windowBackgroundColor),
        pane: Color(nsColor: .textBackgroundColor),
        accent: nil,
        added: .adaptive(light: .hex(0xD9F2D9), dark: .hex(0x1F3621)),
        removed: .adaptive(light: .hex(0xFADEDE), dark: .hex(0x401F21))
    )

    static let all: [Theme] = [
        system,
        Theme(id: "dark", name: "Dark", scheme: .dark,
              tabBar: .hex(0x191A1E), toolbar: .hex(0x2A2B30), sidebar: .hex(0x202125),
              panel: .hex(0x25262B), pane: .hex(0x1E1E21), accent: nil,
              added: .hex(0x1F3621), removed: .hex(0x401F21)),
        Theme(id: "light", name: "Light", scheme: .light,
              tabBar: .hex(0xD9D9D9), toolbar: .hex(0xF7F7F7), sidebar: .hex(0xEEEEEE),
              panel: .hex(0xF2F2F2), pane: .hex(0xFFFFFF), accent: nil,
              added: .hex(0xD9F2D9), removed: .hex(0xFADEDE)),
        Theme(id: "dark-hc", name: "Dark – High Contrast", scheme: .dark,
              tabBar: .hex(0x000000), toolbar: .hex(0x141414), sidebar: .hex(0x0A0A0A),
              panel: .hex(0x0F0F0F), pane: .hex(0x000000), accent: .hex(0x4FC3F7),
              added: .hex(0x0F4A1A), removed: .hex(0x5A1018)),
        Theme(id: "midnight", name: "Midnight", scheme: .dark,
              tabBar: .hex(0x0E1320), toolbar: .hex(0x1A2133), sidebar: .hex(0x131A29),
              panel: .hex(0x161D2D), pane: .hex(0x0F1522), accent: .hex(0x7AA2F7),
              added: .hex(0x1B3A2E), removed: .hex(0x3F1F2C)),
        Theme(id: "nightshade", name: "Nightshade", scheme: .dark,
              tabBar: .hex(0x18141F), toolbar: .hex(0x261F33), sidebar: .hex(0x1E1929),
              panel: .hex(0x221C2E), pane: .hex(0x1A1623), accent: .hex(0xBD93F9),
              added: .hex(0x203D2A), removed: .hex(0x47202F)),
        Theme(id: "forest", name: "Forest", scheme: .dark,
              tabBar: .hex(0x111813), toolbar: .hex(0x1C2720), sidebar: .hex(0x16201A),
              panel: .hex(0x19241D), pane: .hex(0x121A15), accent: .hex(0x6FCF97),
              added: .hex(0x1F4A2C), removed: .hex(0x4A2420)),
        Theme(id: "ember", name: "Ember", scheme: .dark,
              tabBar: .hex(0x1B1411), toolbar: .hex(0x2A201B), sidebar: .hex(0x221A16),
              panel: .hex(0x261D18), pane: .hex(0x1D1613), accent: .hex(0xFF8A4C),
              added: .hex(0x253F22), removed: .hex(0x4A1F18)),
        // Monokai Pro palette: charcoal #2D2A2E, pink #FF6188; accent follows macOS like Dark.
        Theme(id: "monokai-pro", name: "Monokai Pro", scheme: .dark,
              tabBar: .hex(0x19181A), toolbar: .hex(0x221F22), sidebar: .hex(0x221F22),
              panel: .hex(0x272428), pane: .hex(0x2D2A2E), accent: nil,
              added: .hex(0x2F5A32), removed: .hex(0x613844),
              lanes: [.hex(0x78DCE8), .hex(0xAB9DF2), .hex(0xFC9867), .hex(0xFF6188), .hex(0xA9DC76), .hex(0xFFD866)],
              syntax: .monokaiPro),
        Theme(id: "sand", name: "Sand", scheme: .light,
              tabBar: .hex(0xE6DDC8), toolbar: .hex(0xFBF6E9), sidebar: .hex(0xF2EAD7),
              panel: .hex(0xF6F0E1), pane: .hex(0xFDF9EF), accent: .hex(0xB5651D),
              added: .hex(0xDCEBC8), removed: .hex(0xF4D3C8)),
    ]
}

/// Applies the chosen theme to everything inside: accent, light/dark, and a redraw when it changes.
struct ThemedRoot<Content: View>: View {
    @AppStorage(Theme.key) private var themeID = Theme.system.id
    @ViewBuilder let content: () -> Content

    var body: some View {
        let theme = Theme.named(themeID)
        content()
            .id(themeID)
            .tint(theme.accent)
            .onAppear { NSApp.appearance = theme.appearance }
            .onChange(of: themeID) { NSApp.appearance = Theme.named(themeID).appearance }
    }
}

// MARK: - Colors

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32) -> Color { Color(nsColor: .hex(value)) }

    static var byTabBar: Color { Theme.current.tabBar }
    static var byToolbar: Color { Theme.current.toolbar }
    static var bySidebar: Color { Theme.current.sidebar }
    static var byPanel: Color { Theme.current.panel }
    static var byPane: Color { Theme.current.pane }
    static var byAccent: Color { Theme.current.accent ?? .accentColor }
    static let byHairline = Color.primary.opacity(0.09)
}

extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Editor font

/// Settings › Editor: font and layout of diffs.
enum EditorPrefs {
    static let fontKey = "editorFontFamily"      // "" = system monospaced
    static let sizeKey = "editorFontSize"
    static let tabKey = "editorTabSize"
    static let lineNumbersKey = "editorLineNumbers"
    static let wrapKey = "editorWordWrap"
    static let monoOnlyKey = "editorMonoOnly"

    static func font(family: String, size: Double) -> Font {
        if !family.isEmpty,
           let ns = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(ns as CTFont)
        }
        return .system(size: size, design: .monospaced)
    }

    static let allFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    static let monospaceFamilies: [String] = allFamilies.filter { family in
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }
}

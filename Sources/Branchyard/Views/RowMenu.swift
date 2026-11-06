import SwiftUI
import AppKit

/// One entry of a right-click menu built by `RowMenu`.
enum RowMenuItem {
    case action(String, () -> Void)
    case divider
}

/// Right-click menu for a list row, shown by AppKit right at the mouse.
/// SwiftUI's own list menus can open in the wrong place (mirrored to the top of the screen),
/// so rows put this behind their content: `.background(RowMenu { items })`.
/// It only takes right-clicks; normal clicks go straight through to the list.
struct RowMenu: NSViewRepresentable {
    let items: () -> [RowMenuItem]

    init(_ items: @escaping () -> [RowMenuItem]) { self.items = items }

    func makeNSView(context: Context) -> RowMenuView { RowMenuView() }
    func updateNSView(_ view: RowMenuView, context: Context) { view.items = items }
}

final class RowMenuView: NSView {
    var items: () -> [RowMenuItem] = { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let menuClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return menuClick ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click.
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = items()
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .divider:
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            case .action(let title, let run):
                menu.addItem(ClosureMenuItem(title: title, run: run))
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

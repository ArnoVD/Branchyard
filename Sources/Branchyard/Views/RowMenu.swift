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
/// The list's cell takes the click itself, so a window-level monitor finds the
/// RowMenuView inside the clicked cell and opens its menu.
struct RowMenu: NSViewRepresentable {
    let items: () -> [RowMenuItem]

    init(_ items: @escaping () -> [RowMenuItem]) { self.items = items }

    func makeNSView(context: Context) -> RowMenuView {
        RowMenuView.installMonitor()
        return RowMenuView()
    }
    func updateNSView(_ view: RowMenuView, context: Context) { view.items = items }
}

final class RowMenuView: NSView {
    var items: () -> [RowMenuItem] = { [] }

    /// Never the target of clicks: the monitor below hands it right-clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static var monitor: Any?

    static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
            guard let window = event.window, let root = window.contentView?.superview,
                  let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
                  let row = rowMenuView(around: hit, at: event.locationInWindow),
                  let menu = row.buildMenu() else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: row)
            return nil
        }
    }

    /// The RowMenuView under the click: inside the clicked view or one of its few nearest ancestors (the cell).
    private static func rowMenuView(around hit: NSView, at point: NSPoint) -> RowMenuView? {
        var view: NSView? = hit
        for _ in 0..<4 {
            guard let current = view else { return nil }
            if let found = find(in: current, at: point, depth: 4) { return found }
            view = current.superview
        }
        return nil
    }

    private static func find(in view: NSView, at point: NSPoint, depth: Int) -> RowMenuView? {
        if let row = view as? RowMenuView, !row.isHiddenOrHasHiddenAncestor,
           row.bounds.contains(row.convert(point, from: nil)) { return row }
        guard depth > 0 else { return nil }
        for sub in view.subviews.reversed() {
            if let found = find(in: sub, at: point, depth: depth - 1) { return found }
        }
        return nil
    }

    func buildMenu() -> NSMenu? {
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

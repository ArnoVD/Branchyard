import AppKit

/// Test hooks driven by environment variables, for checks without touching the real mouse:
/// - `BRANCHYARD_OPEN=<repo path>` opens that repository in a tab.
/// - `BRANCHYARD_RIGHTCLICK=<x>,<y>` (window points, from the top left) sends a right-click there
///   after 4 s, logs any menu that opens with its screen frame, then quits.
enum DebugHooks {
    @MainActor
    static func run(state: AppState) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["BRANCHYARD_OPEN"] { state.open(URL(fileURLWithPath: path)) }
        guard let spec = env["BRANCHYARD_RIGHTCLICK"] else { return }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            let height = window.contentView?.frame.height ?? window.frame.height
            let point = NSPoint(x: parts[0], y: height - parts[1])
            let screen = window.convertPoint(toScreen: point)
            log("window \(window.frame) click window=\(point) screen=\(screen)")
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                let titles = (note.object as? NSMenu)?.items.map(\.title) ?? []
                let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                    for w in NSApp.windows where w.isVisible && w !== window {
                        log("visible window \(type(of: w)) frame=\(w.frame)")
                    }
                    log("menu items: \(titles)")
                    exit(0)
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { log("no menu opened"); exit(1) }
        }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(("[debug] " + text + "\n").data(using: .utf8)!)
    }
}

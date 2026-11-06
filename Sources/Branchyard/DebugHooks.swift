import AppKit

/// Test hooks driven by environment variables, for checks without touching the real mouse:
/// - `BRANCHYARD_OPEN=<repo path>` opens that repository in a tab.
/// - `BRANCHYARD_SELECT_FIRST_FILE=1` opens the diff of the first changed file.
/// - `BRANCHYARD_COMMIT=<message>` commits what's staged after 1.5 s, pushing too when
///   "Push after committing" is on.
/// - `BRANCHYARD_AMEND=1` turns on "Amend previous commit" after 1 s.
/// - `BRANCHYARD_SHEET=tag|rename|upstream` opens that sheet (HEAD / current branch) after 1.5 s.
/// - `BRANCHYARD_RIGHTCLICK=<x>,<y>` (window points, from the top left) sends a right-click there
///   after 4 s, logs any menu that opens with its screen frame, then quits.
enum DebugHooks {
    @MainActor
    static func run(state: AppState) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["BRANCHYARD_OPEN"] { state.open(URL(fileURLWithPath: path)) }
        if env["BRANCHYARD_SELECT_FIRST_FILE"] != nil {
            // Opens the diff of the first changed file once the repository has loaded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                state.selectedTab?.selectedChangeID = state.selectedTab?.status.allChanges.first?.id
            }
        }
        if env["BRANCHYARD_AMEND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { state.selectedTab?.amend = true }
        }
        if let sheet = env["BRANCHYARD_SHEET"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let tab = state.selectedTab, let head = tab.graph.first(where: { !$0.commit.isWIP })?.commit else { return }
                let current = tab.localBranches.first(where: \.isCurrent)
                switch sheet {
                case "tag": tab.newTagRequest = NewTagRequest(sha: head.sha, subject: head.subject)
                case "rename": current.map { tab.branchRequest = BranchRequest(kind: .rename, branch: $0) }
                case "upstream": current.map { tab.branchRequest = BranchRequest(kind: .upstream, branch: $0) }
                default: break
                }
            }
        }
        if let message = env["BRANCHYARD_COMMIT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let tab = state.selectedTab else { return }
                tab.commitMessage = message
                tab.commit(andPush: UserDefaults.standard.bool(forKey: "commit.pushAfter"))
            }
        }
        if let spec = env["BRANCHYARD_DRAG"] { drag(spec) }
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

    /// `BRANCHYARD_DRAG=x1,y1,x2,y2` (window points, from the top left): presses at the first point
    /// after 2 s, drags to the second and lets go. The same point twice is a click.
    @MainActor
    private static func drag(_ spec: String) {
        let p = spec.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            let height = window.contentView?.frame.height ?? window.frame.height
            let from = NSPoint(x: p[0], y: height - p[1]), to = NSPoint(x: p[2], y: height - p[3])
            let before = window.frame.origin
            var steps: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, from)]
            if from != to {
                for i in 1...10 {
                    let t = Double(i) / 10
                    steps.append((.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
                }
            }
            steps.append((.leftMouseUp, to))
            for (type, point) in steps {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                log("drag done, window moved: \(window.frame.origin != before)")
            }
        }
    }
}

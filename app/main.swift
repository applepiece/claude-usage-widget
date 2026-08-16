// Claude Usage — tiny always-on-top floating widget (Codex-pets style)
// Shows 5-hour + weekly limit bars with reset times, data from the local
// server.py proxy (which owns OAuth refresh against the real account).
import Cocoa
import ServiceManagement

let widgetDir = ("~/claude-usage-widget" as NSString).expandingTildeInPath
let apiURL = URL(string: "http://127.0.0.1:8737/api/usage")!
let pingURL = URL(string: "http://127.0.0.1:8737/api/ping")!
let accountURL = URL(string: "http://127.0.0.1:8737/api/account")!
let loginURL = URL(string: "http://127.0.0.1:8737/api/login")!
let logoutURL = URL(string: "http://127.0.0.1:8737/api/logout")!

// What the menu-bar status item shows next to the Claw'd glyph.
enum BarMode: String { case off, five, seven, both }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var view: WidgetView!
    var statusItem: NSStatusItem?
    var failCount = 0
    var lastReset5: String?
    var lastReset7: String?
    var account = AccountInfo(logged_in: false)
    var latestUsage: Usage?

    var barMode: BarMode {
        get { BarMode(rawValue: UserDefaults.standard.string(forKey: "barMode") ?? "") ?? .five }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "barMode") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // single instance — a second launch just exits
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty { NSApp.terminate(nil); return }
        }

        NSApp.setActivationPolicy(.accessory)
        registerPixelFont()

        // launch at login (idempotent; user-visible in System Settings › Login Items)
        try? SMAppService.mainApp.register()

        let rect = NSRect(x: 0, y: 0, width: 216, height: 74)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false  // WidgetView drags manually
        panel.hidesOnDeactivate = false

        view = WidgetView(frame: rect)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        if let saved = UserDefaults.standard.string(forKey: "pos") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let scr = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: scr.visibleFrame.maxX - rect.width - 16,
                                         y: scr.visibleFrame.maxY - rect.height - 12))
        }
        panel.orderFrontRegardless()

        // right-click menu (rebuilt each open so checkmarks reflect state);
        // click Claw'd's legs to tuck the widget into the menu bar
        view.menuProvider = { [weak self] in self?.buildMenu(minimized: false) ?? NSMenu() }
        view.onLegClick = { [weak self] in self?.minimizeToMenuBar() }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "pos")
        }

        // restore the tucked-away state from last session
        if UserDefaults.standard.bool(forKey: "minimized") { minimizeToMenuBar() }

        ensureServer()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.refresh() }
        // Claw'd animation clock (~20fps)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            self.view.t += 1.0 / 20.0
            self.view.needsDisplay = true
        }
    }

    // ================= menu-bar (collapsed) mode =================

    @objc func minimizeToMenuBar() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = WidgetView.menuBarIcon()
            item.button?.imagePosition = .imageLeading
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        updateStatusItem()
        panel.orderOut(nil)
        UserDefaults.standard.set(true, forKey: "minimized")
    }

    @objc func restoreFromMenuBar() {
        panel.orderFrontRegardless()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        UserDefaults.standard.set(false, forKey: "minimized")
    }

    // left-click the glyph → reopen the widget; right/ctrl-click → options menu
    @objc func statusClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            let menu = buildMenu(minimized: true)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            restoreFromMenuBar()
        }
    }

    private func pctText(_ v: (pct: Double, when: String)?) -> String {
        guard !view.offline, !view.signedOut, let v else { return "–" }
        return "\(Int(v.pct.rounded()))%"
    }

    // percentage string shown next to the glyph, per the chosen BarMode
    private func statusText() -> String {
        switch barMode {
        case .off:   return ""
        case .five:  return pctText(view.five)
        case .seven: return pctText(view.seven)
        case .both:  return pctText(view.five) + " · " + pctText(view.seven)
        }
    }

    func updateStatusItem() {
        guard let btn = statusItem?.button else { return }
        let txt = statusText()
        if txt.isEmpty {
            btn.attributedTitle = NSAttributedString(string: "")
        } else {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            btn.attributedTitle = NSAttributedString(
                string: " " + txt,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
    }

    @objc func setBarMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = BarMode(rawValue: raw) {
            barMode = m
        }
        updateStatusItem()
    }

    func buildMenu(minimized: Bool) -> NSMenu {
        let menu = NSMenu()
        for item in UsageMenuViews.items(account: account, usage: latestUsage) {
            menu.addItem(item)
        }

        if !account.logged_in {
            let signIn = NSMenuItem(title: "Sign In to Claude…",
                                    action: #selector(startLogin), keyEquivalent: "")
            signIn.target = self
            menu.addItem(signIn)
            menu.addItem(.separator())
        } else {
            menu.addItem(.separator())
        }

        if minimized {
            let s = NSMenuItem(title: "Show Widget", action: #selector(restoreFromMenuBar), keyEquivalent: "")
            s.target = self
            menu.addItem(s)
        } else {
            let m = NSMenuItem(title: "Minimize to Menu Bar", action: #selector(minimizeToMenuBar), keyEquivalent: "m")
            m.target = self
            menu.addItem(m)
        }

        let disp = NSMenuItem(title: "Menu Bar %", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let options: [(String, BarMode)] = [
            ("Off", .off), ("5-Hour only", .five), ("Weekly only", .seven), ("Both", .both),
        ]
        for (title, mode) in options {
            let it = NSMenuItem(title: title, action: #selector(setBarMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = (barMode == mode) ? .on : .off
            sub.addItem(it)
        }
        disp.submenu = sub
        menu.addItem(disp)

        let r = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Usage Settings…",
                                  action: #selector(openUsageSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        if account.logged_in {
            let switchAccount = NSMenuItem(title: "Switch Account…",
                                           action: #selector(startLogin), keyEquivalent: "")
            switchAccount.target = self
            menu.addItem(switchAccount)
            let signOut = NSMenuItem(title: "Sign Out", action: #selector(confirmSignOut),
                                     keyEquivalent: "")
            signOut.target = self
            menu.addItem(signOut)
        }
        menu.addItem(.separator())

        let q = NSMenuItem(title: "Quit Claude Usage", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
        return menu
    }

    @objc func openUsageSettings() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func startLogin() {
        postAuth(to: loginURL) { [weak self] ok in
            guard let self else { return }
            if ok {
                // signing in is exactly when identity changes, so the staleness
                // gate must not hold the old account on screen
                self.lastAccountFetch = nil
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.lastAccountFetch = nil
                    self.refresh()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    self.lastAccountFetch = nil
                    self.refresh()
                }
            } else {
                self.showAuthError("Could not start Claude sign in.")
            }
        }
    }

    @objc func confirmSignOut() {
        let email = account.email ?? "the current account"
        let alert = NSAlert()
        alert.messageText = "Sign out of Claude Code?"
        alert.informativeText = "This signs out \(email). The claude CLI on this Mac will need a fresh login."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        // accessory apps have no menu-bar focus, so the sheet can open behind
        // whatever is frontmost unless we take activation first
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        postAuth(to: logoutURL) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.lastAccountFetch = nil
                self.account = AccountInfo(logged_in: false)
                self.latestUsage = nil
                self.view.signedOut = true
                self.view.offline = false
                self.updateStatusItem()
                self.view.needsDisplay = true
                self.refresh()
            } else {
                self.showAuthError("Could not sign out of Claude Code.")
            }
        }
    }

    private func postAuth(to url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "X-Widget")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion((200..<300).contains(status)) }
        }.resume()
    }

    private func showAuthError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Make sure the local usage server and Claude Code are installed."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func quit() { NSApp.terminate(nil) }

    func ensureServer() {
        URLSession.shared.dataTask(with: pingURL) { data, _, _ in
            if data == nil {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = [widgetDir + "/server.py"]
                p.standardOutput = nil
                p.standardError = nil
                try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.refresh() }
            }
        }.resume()
    }

    // Identity changes only at sign in or sign out, so polling it on the same
    // 60s clock as usage would double this app's API traffic for nothing.
    private var lastAccountFetch: Date?
    private let accountMaxAge: TimeInterval = 10 * 60

    private func refreshAccountIfStale() {
        if let last = lastAccountFetch, Date().timeIntervalSince(last) < accountMaxAge {
            return
        }
        refreshAccount()
    }

    private func refreshAccount() {
        URLSession.shared.dataTask(with: accountURL) { data, _, _ in
            guard let data, let account = try? JSONDecoder().decode(AccountInfo.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                self.lastAccountFetch = Date()
                self.account = account
                self.view.signedOut = !account.logged_in
                if !account.logged_in { self.view.offline = false }
                self.updateStatusItem()
                self.view.needsDisplay = true
            }
        }.resume()
    }

    @objc func refresh() {
        refreshAccountIfStale()
        URLSession.shared.dataTask(with: apiURL) { data, _, _ in
            DispatchQueue.main.async {
                guard let data, let u = try? JSONDecoder().decode(Usage.self, from: data) else {
                    // transient failure: keep the last known values on screen;
                    // only flag offline after 3 misses in a row (~3 min)
                    self.failCount += 1
                    if self.failCount >= 3, !self.view.signedOut { self.view.offline = true }
                    self.view.needsDisplay = true
                    return
                }
                self.failCount = 0
                self.latestUsage = u

                if u.logged_in == false {
                    self.account = AccountInfo(logged_in: false)
                    self.view.signedOut = true
                    self.view.offline = false
                    self.updateStatusItem()
                    self.view.needsDisplay = true
                    return
                }
                self.view.signedOut = false

                // A limit that just reset can come back with resets_at = null —
                // that is a fresh window, not a disconnect. Show the pct with
                // "READY" instead of wiping the row.
                func conv(_ l: LimitInfo?) -> (Double, String)? {
                    guard let l, let p = l.utilization else { return nil }
                    if let rs = l.resets_at, let d = parseISO(rs) { return (p, fmtWhen(d)) }
                    return (p, "READY")
                }
                // keep previous values when a field is missing entirely
                if let f = conv(u.five_hour) { self.view.five = f }
                if let s = conv(u.seven_day) { self.view.seven = s }
                self.view.offline = (self.view.five == nil && self.view.seven == nil)

                // celebrate a reset: resets_at changed to a later window
                let r5 = u.five_hour?.resets_at
                let r7 = u.seven_day?.resets_at
                if (self.lastReset5 != nil && r5 != self.lastReset5)
                    || (self.lastReset7 != nil && r7 != self.lastReset7) {
                    self.view.danceUntil = self.view.t + 8
                }
                if r5 != nil { self.lastReset5 = r5 }
                if r7 != nil { self.lastReset7 = r7 }

                self.updateStatusItem()
                self.view.needsDisplay = true
            }
        }.resume()
    }
}

final class MenuPreviewCanvas: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func renderMenuPreview(path: String, dark: Bool, signedOut: Bool) -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let now = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func reset(after seconds: TimeInterval) -> String {
        formatter.string(from: now.addingTimeInterval(seconds + 60))
    }

    let account = signedOut
        ? AccountInfo(logged_in: false)
        : AccountInfo(logged_in: true, email: "kriengkrai.pho@gmail.com",
                      name: "heng", plan: "max")
    let usage = signedOut ? nil : Usage(
        limits: [
            LimitInfo(resets_at: reset(after: 3 * 60 * 60), kind: "session",
                      group: "session", percent: 24),
            LimitInfo(resets_at: reset(after: 5 * 24 * 60 * 60), kind: "weekly_all",
                      group: "weekly", percent: 8),
            LimitInfo(resets_at: reset(after: 5 * 24 * 60 * 60), kind: "weekly_scoped",
                      group: "weekly", percent: 94,
                      scope: LimitScope(model: LimitModel(display_name: "Fable"))),
        ],
        fetched_at: now.addingTimeInterval(-15).timeIntervalSince1970,
        logged_in: true)
    let items = UsageMenuViews.items(account: account, usage: usage, now: now)
    let padding: CGFloat = 8
    let height = items.reduce(padding * 2) { $0 + ($1.view?.frame.height ?? 0) }
    let canvas = MenuPreviewCanvas(frame: NSRect(x: 0, y: 0, width: 336, height: height))
    canvas.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    var y = height - padding
    for item in items {
        guard let view = item.view else { continue }
        item.view = nil
        y -= view.frame.height
        view.frame.origin = NSPoint(x: padding, y: y)
        view.isHidden = false
        canvas.addSubview(view)
    }
    canvas.layoutSubtreeIfNeeded()
    guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
        return 1
    }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return 1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    canvas.displayIgnoringOpacity(canvas.bounds, in: context)
    func drawSubviews(of parent: NSView) {
        for view in parent.subviews where !view.isHidden {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: view.frame.minX, yBy: view.frame.minY)
            transform.concat()
            view.displayIgnoringOpacity(view.bounds, in: context)
            drawSubviews(of: view)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    drawSubviews(of: canvas)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        return 1
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        return 0
    } catch {
        return 1
    }
}

if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--preview-menu" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    exit(renderMenuPreview(path: arguments[0],
                           dark: arguments.contains("--dark"),
                           signedOut: arguments.contains("--signed-out")))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// Claude Usage — tiny always-on-top floating widget (Codex-pets style)
// Shows 5-hour + weekly limit bars with reset times, data from the local
// server.py proxy (which owns OAuth refresh against the real account).
import Cocoa
import ServiceManagement

let widgetDir = ("~/claude-usage-widget" as NSString).expandingTildeInPath
let apiURL = URL(string: "http://127.0.0.1:8737/api/usage")!
let pingURL = URL(string: "http://127.0.0.1:8737/api/ping")!

// What the menu-bar status item shows next to the Claw'd glyph.
enum BarMode: String { case off, five, seven, both }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var view: WidgetView!
    var statusItem: NSStatusItem?
    var failCount = 0
    var lastReset5: String?
    var lastReset7: String?

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
        guard !view.offline, let v else { return "–" }
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
        if minimized {
            let s = NSMenuItem(title: "Show Widget", action: #selector(restoreFromMenuBar), keyEquivalent: "")
            s.target = self
            menu.addItem(s)
        } else {
            let m = NSMenuItem(title: "Minimize to Menu Bar", action: #selector(minimizeToMenuBar), keyEquivalent: "m")
            m.target = self
            menu.addItem(m)
        }
        menu.addItem(.separator())

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
        menu.addItem(.separator())

        let r = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "Quit Claude Usage", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
        return menu
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

    @objc func refresh() {
        URLSession.shared.dataTask(with: apiURL) { data, _, _ in
            DispatchQueue.main.async {
                guard let data, let u = try? JSONDecoder().decode(Usage.self, from: data) else {
                    // transient failure: keep the last known values on screen;
                    // only flag offline after 3 misses in a row (~3 min)
                    self.failCount += 1
                    if self.failCount >= 3 { self.view.offline = true }
                    self.view.needsDisplay = true
                    return
                }
                self.failCount = 0

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

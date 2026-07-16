// Claude Usage — tiny always-on-top floating widget (Codex-pets style)
// Shows 5-hour + weekly limit bars with reset times, data from the local
// server.py proxy (which owns OAuth refresh against the real account).
import Cocoa
import ServiceManagement

let widgetDir = ("~/claude-usage-widget" as NSString).expandingTildeInPath
let apiURL = URL(string: "http://127.0.0.1:8737/api/usage")!
let pingURL = URL(string: "http://127.0.0.1:8737/api/ping")!

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var view: WidgetView!
    var failCount = 0
    var lastReset5: String?
    var lastReset7: String?

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

        let rect = NSRect(x: 0, y: 0, width: 240, height: 96)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
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

        let menu = NSMenu()
        let r = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "Quit Claude Usage", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
        view.menu = menu

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "pos")
        }

        ensureServer()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.refresh() }
        // Claw'd animation clock (~20fps)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            self.view.t += 1.0 / 20.0
            self.view.needsDisplay = true
        }
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

                self.view.needsDisplay = true
            }
        }.resume()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

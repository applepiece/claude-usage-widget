// Claude Usage 3.0 · AppKit only. Credentials stay in the local Python server.
import Cocoa
import ServiceManagement
import UsageKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    let canvas = NSView()
    let view = WidgetView(frame: .zero)
    let secondaryView = WidgetView(frame: .zero)
    var statusItem: NSStatusItem?
    var appearanceObservation: NSKeyValueObservation?
    var accounts: [UsageAccount] = []
    var failCount = 0
    var refreshing = false
    var refreshPending = false
    var switchWatch: Timer?
    var previous: [String: UsageAccount] = [:]
    var danceEnds: [String: Date] = [:]

    let preferences: Preferences
    let client = UsageClient()
    let serverProcess = ServerProcess()
    var animationTimer: Timer?
    var refreshTimer: Timer?
    var loginDeadline = Date.distantPast

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        registerPixelFont()
        preferences.migrate()
        try? SMAppService.mainApp.register()
        let rect = NSRect(x: 0, y: 0, width: 216, height: 74)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        self.panel = panel
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        canvas.frame = rect
        panel.contentView = canvas
        view.frame = rect
        secondaryView.frame = rect
        secondaryView.showsMascot = false
        for widget in [view, secondaryView] {
            canvas.addSubview(widget)
            widget.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
            widget.onLegClick = { [weak self] in self?.minimizeToMenuBar() }
        }
        if let saved = preferences.defaults.string(forKey: "pos") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - rect.width - 16,
                                         y: screen.visibleFrame.maxY - rect.height - 12))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
        if !preferences.defaults.bool(forKey: "minimized") {
            panel.orderFrontRegardless()
            startAnimation()
        }
        updateUI()
        Task {
            await serverProcess.ensureServer(client: client)
            refresh()
        }
        refreshTimer = Timer.scheduledTimer(timeInterval: 60, target: self,
                                            selector: #selector(refresh), userInfo: nil, repeats: true)
        refreshTimer?.tolerance = 6
    }

    @objc func panelMoved() {
        guard let panel else { return }
        preferences.defaults.set(NSStringFromPoint(panel.frame.origin), forKey: "pos")
    }

    func startAnimation() {
        guard animationTimer == nil, panel?.isVisible == true else { return }
        animationTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self,
                                              selector: #selector(animateWidget), userInfo: nil, repeats: true)
        animationTimer?.tolerance = 0.005
    }

    @objc func animateWidget() {
        guard panel?.isVisible == true else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        for widget in [view, secondaryView] {
            widget.t += 0.05
            widget.needsDisplay = true
        }
    }

    @objc func minimizeToMenuBar() {
        panel?.orderOut(nil)
        animationTimer?.invalidate()
        animationTimer = nil
        preferences.defaults.set(true, forKey: "minimized")
        updateStatusItem()
    }
    @objc func restoreFromMenuBar() {
        panel?.orderFrontRegardless()
        startAnimation()
        preferences.defaults.set(false, forKey: "minimized")
        updateStatusItem()
    }
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem?.menu = buildMenu()
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else { restoreFromMenuBar() }
    }

    func updateStatusItem() {
        guard let panel else { return }
        let needed = preferences.always || !panel.isVisible
        if !needed {
            appearanceObservation = nil
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
            appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateStatusItem() }
            }
        }
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = StatusRenderer.image(accounts: preferences.shown(in: accounts), tags: accountTags(accounts),
                                             style: preferences.style, metric: preferences.metric,
                                             numbers: preferences.numbers, appearance: button.effectiveAppearance)
        button.toolTip = accounts.isEmpty ? "Claude Usage · No accounts" : preferences.shown(in: accounts).map {
            "\($0.label) · \($0.providerName): 5H \(percentage($0.fiveHour)), WK \(percentage($0.sevenDay)) · \($0.rawState)"
        }.joined(separator: "\n")
        button.setAccessibilityLabel(button.toolTip)
    }

    func updateUI() {
        guard let panel else { return }
        let primary = preferences.primary(in: accounts)
        let secondary = preferences.twoWidgets ? preferences.secondary(in: accounts) : nil
        let height: CGFloat = secondary == nil ? 74 : 148
        if panel.frame.height != height {
            var frame = panel.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: false)
        }
        canvas.frame.size = NSSize(width: 216, height: height)
        view.frame = NSRect(x: 0, y: height - 74, width: 216, height: 74)
        secondaryView.frame = NSRect(x: 0, y: 0, width: 216, height: 74)
        secondaryView.isHidden = secondary == nil
        let tags = accountTags(accounts)
        func apply(_ account: UsageAccount?, to widget: WidgetView) {
            widget.accountTag = secondary == nil ? "" : (account.flatMap { tags[$0.id] } ?? "")
            widget.signedOut = account == nil
            // a stale snapshot is still the last known truth; only a dead account reads OFFLINE
            widget.offline = account.map { $0.state != .ok && $0.state != .stale } ?? false
            func convert(_ limit: LimitInfo?) -> (Double, String)? {
                guard let limit, let value = limit.value else { return nil }
                return (value, limit.resetsAt.flatMap(parseISO).map { fmtWhen($0) } ?? "READY")
            }
            widget.five = convert(account?.fiveHour)
            widget.seven = convert(account?.sevenDay)
            if let id = account?.id, let end = danceEnds[id] {
                widget.danceUntil = widget.t + CGFloat(max(0, end.timeIntervalSinceNow))
            } else { widget.danceUntil = -1 }
            widget.needsDisplay = true
        }
        apply(primary, to: view)
        apply(secondary, to: secondaryView)
        updateStatusItem()
    }

    func percentage(_ limit: LimitInfo?) -> String {
        limit?.value.map { "\(Int($0.rounded()))%" } ?? "–"
    }
    func receive(_ fresh: [UsageAccount]?) {
        refreshing = false
        if let fresh {
            failCount = 0
            for account in fresh where account.state == .ok {
                if let old = previous[account.id], old.state == .ok {
                    func reset(_ before: LimitInfo?, _ after: LimitInfo?) -> Bool {
                        guard let before, let after, before.value != nil, after.value != nil else { return false }
                        if let oldDate = before.resetsAt.flatMap(parseISO) {
                            if let newDate = after.resetsAt.flatMap(parseISO) { return newDate > oldDate }
                            return after.value == 0 && oldDate <= Date()
                        }
                        return false
                    }
                    if reset(old.fiveHour, account.fiveHour) || reset(old.sevenDay, account.sevenDay) {
                        danceEnds[account.id] = Date().addingTimeInterval(8)
                    }
                }
                previous[account.id] = account
            }
            accounts = fresh
            if preferences.primaryID == nil, let primary = preferences.primary(in: fresh) {
                preferences.defaults.set(primary.id, forKey: "primaryAccount")
            }
        } else {
            failCount += 1
            // Keep the snapshot visibly stale from the first transport failure.
            accounts = accounts.map { var a = $0; if a.state == .ok { a.state = .stale }; return a }
        }
        updateUI()
        if refreshPending { refreshPending = false; refreshNow() }
    }
    @objc func refreshNow() {
        guard !refreshing else { refreshPending = true; return }
        guard !accounts.isEmpty else { refresh(); return }
        refreshing = true
        Task {
            await client.refresh(accounts: accounts)
            refreshing = false
            refreshPending = false
            refresh()
        }
    }

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { receive(await client.accounts()) }
    }

    @objc func startLogin() {
        Task {
            guard await client.post("login") else {
                showAuthError("Could not start Claude sign in.")
                return
            }
            refresh()
            startLoginWatch()
        }
    }

    func startLoginWatch() {
        switchWatch?.invalidate()
        loginDeadline = Date().addingTimeInterval(180)
        switchWatch = Timer.scheduledTimer(timeInterval: 5, target: self,
                                           selector: #selector(watchLogin), userInfo: nil, repeats: true)
        switchWatch?.tolerance = 0.5
    }

    @objc func watchLogin() {
        guard Date() < loginDeadline else { switchWatch?.invalidate(); switchWatch = nil; return }
        refresh()
    }

    @objc func confirmSignOut() {
        let email = accounts.first(where: { $0.machineLogin })?.email ?? "the current account"
        let alert = NSAlert()
        alert.messageText = "Sign out of Claude Code?"
        alert.informativeText = "This signs out \(email). The claude CLI on this Mac will need a fresh login."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if await client.post("logout") { refresh() }
            else { showAuthError("Could not sign out of Claude Code.") }
        }
    }
    func showAuthError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message
        alert.informativeText = "Make sure the local usage server and Claude Code are installed."
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc func openUsageSettings() { NSWorkspace.shared.open(AppURLs.claudeSettings) }
    @objc func openCodexUsageSettings() { NSWorkspace.shared.open(AppURLs.codexSettings) }
    @objc func quit() { NSApp.terminate(nil) }
}

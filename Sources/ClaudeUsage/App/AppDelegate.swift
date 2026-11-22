// Claude Usage 3.0 · AppKit with native SwiftUI Settings. Credentials stay in the local Python server.
import Cocoa
import UsageKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel?
    let canvas = NSView()
    let view = WidgetView(frame: .zero)
    let secondaryView = WidgetView(frame: .zero)
    var statusItem: NSStatusItem?
    /// What the status button currently shows; nil once the item is gone.
    var renderedStatus: StatusItemContent?
    let model: AppModel
    let qa: QAOptions
    var settingsController: SettingsWindowController?
    var trackingMenu: NSMenu?
    var qaReadySent = false
    var defaultsUpdatePending = false
    var accountsLoaded = false
    var sizingWidget = false
    var accounts: [UsageAccount] {
        get { model.accounts }
        set { model.accounts = newValue }
    }
    var failCount = 0
    var refreshing: Bool {
        get { model.refreshing }
        set { model.refreshing = newValue; updateRefreshMenuItem() }
    }
    var refreshPending = false
    var creditsRefreshing = false
    var switchWatch: Timer?
    var previous: [String: UsageAccount] = [:]
    var danceEnds: [String: Date] = [:]

    let preferences: Preferences
    let client = UsageClient()
    let serverProcess = ServerProcess()
    var animationTimer: Timer?
    var refreshTimer: Timer?
    var loginDeadline = Date.distantPast

    init(preferences: Preferences = Preferences(), qa: QAOptions = QAOptions()) {
        self.preferences = preferences
        self.qa = qa
        self.model = AppModel(preferences: preferences, isQA: qa.enabled)
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if !qa.enabled, let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        registerPixelFont()
        preferences.migrate()
        if qa.enabled {
            if let appearance = qa.appearance {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            accounts = qa.accounts()
            accountsLoaded = true
            model.creditSnapshot = CreditSnapshot(providers: CreditSamples.providers(), updatedAt: Date())
            model.refreshing = qa.state == "refreshing"
        }
        model.widgetAction = { [weak self] visible in
            if visible { self?.restoreFromMenuBar() } else { self?.minimizeToMenuBar() }
        }
        model.refreshAction = { [weak self] in self?.refreshNow() }
        model.signInAction = { [weak self] in self?.startLogin() }
        model.signOutAction = { [weak self] in self?.confirmSignOut() }
        installApplicationMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: preferences.defaults)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        reduceMotionChanged()
        let requestedWidgets = preferences.twoWidgets && preferences.secondaryID != "none" ? 2 : 1
        let widgetCount = accountsLoaded ? (preferences.twoWidgets && preferences.secondary(in: accounts) != nil ? 2 : 1) : requestedWidgets
        let rect = UsageBarLayout.widgetFrame(origin: .zero, barCount: preferences.barSlots.count, widgetCount: widgetCount)
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
        let rowHeight = CGFloat(UsageBarLayout.widgetHeight(count: preferences.barSlots.count))
        view.frame = NSRect(x: 0, y: rect.height - rowHeight, width: 216, height: rowHeight)
        secondaryView.frame = NSRect(x: 0, y: 0, width: 216, height: rowHeight)
        secondaryView.isHidden = widgetCount == 1
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
        if qa.enabled { scheduleQA(); return }
        Task {
            await serverProcess.ensureServer(client: client)
            refresh()
        }
        refreshTimer = Timer.scheduledTimer(timeInterval: 60, target: self,
                                            selector: #selector(refresh), userInfo: nil, repeats: true)
        refreshTimer?.tolerance = 6
    }

    @objc func defaultsChanged() {
        guard !defaultsUpdatePending else { return }
        defaultsUpdatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.defaultsUpdatePending = false
                self.model.preferencesRevision += 1
                let visible = !self.preferences.defaults.bool(forKey: "minimized")
                if visible != self.panel?.isVisible {
                    if visible { self.panel?.orderFrontRegardless(); self.startAnimation() }
                    else {
                        self.panel?.orderOut(nil)
                        self.animationTimer?.invalidate()
                        self.animationTimer = nil
                    }
                }
                self.updateUI(persistWidgetResize: true)
                if let menu = self.trackingMenu {
                    self.updateAccountMenu(in: menu)
                    self.updateCreditsMenu(in: menu)
                }
            }
        }
    }

    @objc func reduceMotionChanged() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for widget in [view, secondaryView] {
            widget.reduceMotion = reduce
            widget.needsDisplay = true
        }
    }

    @objc func panelMoved() {
        guard !sizingWidget, let panel else { return }
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
        updateUI()
    }
    @objc func restoreFromMenuBar() {
        panel?.orderFrontRegardless()
        startAnimation()
        preferences.defaults.set(false, forKey: "minimized")
        updateUI()
    }
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            openStatusMenu()
        } else { restoreFromMenuBar() }
    }

    func openStatusMenu() {
        statusItem?.menu = buildMenu()
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    func updateStatusItem() {
        guard let panel else { return }
        let needed = preferences.always || !panel.isVisible
        if !needed {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            renderedStatus = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // The glyph is a template image and the title carries no color, so
            // AppKit re-tints both when the menu bar's appearance changes. Do not
            // observe effectiveAppearance here: NSStatusItem flips the button's
            // appearance every time it redraws its replicant snapshot, and a redraw
            // in that callback schedules the next snapshot, spinning the main thread.
            item.button?.image = StatusRenderer.glyph()
            item.button?.imagePosition = .imageLeading
            statusItem = item
            renderedStatus = nil
        }
        guard let button = statusItem?.button else { return }
        let content = StatusItemContent(shown: preferences.shown(in: accounts), anyAccounts: !accounts.isEmpty,
                                        shortNames: preferences.effectiveShortNames(in: accounts),
                                        metric: preferences.metric, numbers: preferences.numbers)
        guard content != renderedStatus else { return }
        renderedStatus = content
        button.attributedTitle = StatusRenderer.attributedTitle(content.title)
        button.toolTip = content.toolTip
        button.setAccessibilityLabel(content.title.accessibilityLabel)
    }

    func updateUI(persistWidgetResize: Bool = false) {
        guard let panel else { return }
        model.widgetVisible = panel.isVisible
        model.lastUpdate = accounts.compactMap(MenuFormatting.timestamp).max()
        let primary = preferences.primary(in: accounts)
        let secondary = preferences.twoWidgets ? preferences.secondary(in: accounts) : nil
        let slots = preferences.barSlots
        let rowHeight = CGFloat(UsageBarLayout.widgetHeight(count: slots.count))
        let waitingForSecondary = !accountsLoaded && preferences.twoWidgets && preferences.secondaryID != "none"
        let widgetCount = secondary != nil || waitingForSecondary ? 2 : 1
        let frame = UsageBarLayout.resizedWidgetFrame(panel.frame, barCount: slots.count, widgetCount: widgetCount)
        let height = frame.height
        if panel.frame.height != height {
            sizingWidget = true
            panel.setFrame(frame, display: false)
            sizingWidget = false
            if persistWidgetResize { preferences.defaults.set(NSStringFromPoint(frame.origin), forKey: "pos") }
        }
        canvas.frame.size = NSSize(width: 216, height: height)
        view.frame = NSRect(x: 0, y: height - rowHeight, width: 216, height: rowHeight)
        secondaryView.frame = NSRect(x: 0, y: 0, width: 216, height: rowHeight)
        secondaryView.isHidden = widgetCount == 1
        let tags = preferences.effectiveShortNames(in: accounts)
        func apply(_ account: UsageAccount?, to widget: WidgetView) {
            widget.accountTag = secondary == nil ? "" : (account.flatMap { tags[$0.id] } ?? "")
            widget.signedOut = account == nil
            // a stale snapshot is still the last known truth; only a dead account reads OFFLINE
            widget.offline = account.map { $0.state != .ok && $0.state != .stale } ?? false
            widget.configureBars(account: account, slots: slots)
            if let id = account?.id, let end = danceEnds[id] {
                widget.danceUntil = widget.t + CGFloat(max(0, end.timeIntervalSinceNow))
            } else { widget.danceUntil = -1 }
            widget.needsDisplay = true
        }
        apply(primary, to: view)
        apply(secondary, to: secondaryView)
        updateStatusItem()
        updateRefreshMenuItem()
    }

    func receive(_ fresh: [UsageAccount]?) {
        refreshing = false
        if let fresh {
            accountsLoaded = true
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
        guard !qa.enabled else { return }
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
        guard !qa.enabled else { return }
        guard !refreshing else { return }
        refreshing = true
        refreshCredits(force: true)
        Task { receive(await client.accounts()) }
    }

    func refreshCredits(force: Bool = false) {
        guard !qa.enabled, !creditsRefreshing else { return }
        if !force, let updatedAt = model.creditsUpdatedAt, Date().timeIntervalSince(updatedAt) <= 600 { return }
        creditsRefreshing = true
        Task {
            defer { creditsRefreshing = false }
            // Keep both the last snapshot and its age after a transport/decode failure.
            model.creditSnapshot.receive(await client.credits(), now: Date())
            if let menu = trackingMenu { updateCreditsMenu(in: menu) }
        }
    }

    @objc func startLogin() {
        guard !qa.enabled else { return }
        Task {
            guard await client.post("login") else {
                showAuthError(String(localized: "Could not start Claude sign in."))
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
        guard !qa.enabled else { return }
        let email = accounts.first(where: { $0.machineLogin })?.email ?? String(localized: "the current account")
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign out of Claude Code?")
        alert.informativeText = String(localized: "This signs out \(email). The claude CLI on this Mac will need a fresh login.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Sign Out")); alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if await client.post("logout") { refresh() }
            else { showAuthError(String(localized: "Could not sign out of Claude Code.")) }
        }
    }
    func showAuthError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message
        alert.informativeText = String(localized: "Make sure the local usage server and Claude Code are installed.")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc func openUsageSettings() { NSWorkspace.shared.open(AppURLs.claudeSettings) }
    @objc func openCodexUsageSettings() { NSWorkspace.shared.open(AppURLs.codexSettings) }
    @objc func quit() { NSApp.terminate(nil) }
}

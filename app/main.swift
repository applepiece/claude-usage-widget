// Claude Usage 2.1 · AppKit only. Credentials stay in the local Python server.
import Cocoa
import ServiceManagement

let widgetDir = ("~/Library/Application Support/claude-usage-widget" as NSString).expandingTildeInPath
let baseURL = "http://127.0.0.1:8737"
var preferences = Preferences()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var canvas: NSView!
    var view: WidgetView!
    var secondaryView: WidgetView!
    var statusItem: NSStatusItem?
    var appearanceObservation: NSKeyValueObservation?
    var accounts: [UsageAccount] = []
    var failCount = 0
    var refreshing = false
    var refreshPending = false
    var switchWatch: Timer?
    var previous: [String: UsageAccount] = [:]
    var danceEnds: [String: Date] = [:]

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
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        canvas = NSView(frame: rect)
        panel.contentView = canvas
        view = WidgetView(frame: rect)
        secondaryView = WidgetView(frame: rect)
        secondaryView.showsMascot = false
        for widget in [view!, secondaryView!] {
            canvas.addSubview(widget)
            widget.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
            widget.onLegClick = { [weak self] in self?.minimizeToMenuBar() }
        }
        if let saved = UserDefaults.standard.string(forKey: "pos") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - rect.width - 16,
                                         y: screen.visibleFrame.maxY - rect.height - 12))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "pos")
        }
        if !UserDefaults.standard.bool(forKey: "minimized") { panel.orderFrontRegardless() }
        updateUI()
        ensureServer()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            for widget in [self.view!, self.secondaryView!] {
                widget.t += 0.05
                widget.needsDisplay = true
            }
        }
    }

    @objc func minimizeToMenuBar() {
        panel.orderOut(nil)
        UserDefaults.standard.set(true, forKey: "minimized")
        updateStatusItem()
    }
    @objc func restoreFromMenuBar() {
        panel.orderFrontRegardless()
        UserDefaults.standard.set(false, forKey: "minimized")
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
        guard panel != nil else { return }
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
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
        }
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = StatusRenderer.image(accounts: preferences.shown(in: accounts), tags: accountTags(accounts),
                                             style: preferences.style, metric: preferences.metric,
                                             numbers: preferences.numbers, appearance: button.effectiveAppearance)
        button.toolTip = accounts.isEmpty ? "Claude Usage · No accounts" : preferences.shown(in: accounts).map {
            "\($0.label) · \($0.providerName): 5H \(percentage($0.five_hour)), WK \(percentage($0.seven_day)) · \($0.state)"
        }.joined(separator: "\n")
        button.setAccessibilityLabel(button.toolTip)
    }

    func updateUI() {
        guard panel != nil else { return }
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
            widget.offline = account.map { $0.state != "ok" && $0.state != "stale" } ?? false
            func convert(_ limit: LimitInfo?) -> (Double, String)? {
                guard let limit, let value = limit.value else { return nil }
                return (value, limit.resets_at.flatMap(parseISO).map(fmtWhen) ?? "READY")
            }
            widget.five = convert(account?.five_hour)
            widget.seven = convert(account?.seven_day)
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
    func action(_ title: String, _ selector: Selector, value: Any? = nil, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        return item
    }
    func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(); item.submenu = sub; menu.addItem(item)
        return sub
    }
    func section(_ account: UsageAccount, role: String? = nil, in menu: NSMenu) {
        let usage = account.failed ? nil : account.usage
        for item in UsageMenuViews.items(account: account.info, usage: usage, role: role, state: account.state) {
            menu.addItem(item)
        }
        if account.state == "token_rejected" {
            let title = account.isCodex ? "Renew: bridge-accounts/login-all.sh codex" : "Renew: scripts/add-account.sh \(account.id)"
            let hint = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            hint.isEnabled = false; menu.addItem(hint)
        }
    }
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let primary = preferences.primary(in: accounts)
        let secondary = preferences.secondary(in: accounts)
        if let primary { section(primary, role: "PRIMARY", in: menu) }
        else {
            for item in UsageMenuViews.items(account: AccountInfo(logged_in: false), usage: nil) { menu.addItem(item) }
        }
        if let secondary { menu.addItem(.separator()); section(secondary, role: "SECONDARY", in: menu) }
        let others = accounts.filter { $0.id != primary?.id && $0.id != secondary?.id }
        let tags = accountTags(accounts)
        if !others.isEmpty { menu.addItem(.separator()) }
        let mixed = others.contains { $0.isCodex } && others.contains { !$0.isCodex }
        let grouped = [others.filter { !$0.isCodex }, others.filter { $0.isCodex }].filter { !$0.isEmpty }
        for group in grouped {
            if mixed {
                if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: group[0].providerName)) } else {
                    let heading = NSMenuItem(title: group[0].providerName, action: nil, keyEquivalent: "")
                    heading.isEnabled = false; menu.addItem(heading)
                }
            }
            for account in group {
                let summary = account.failed ? account.state.replacingOccurrences(of: "_", with: " ")
                    : "5H \(percentage(account.five_hour)) · WK \(percentage(account.seven_day))" + (account.state == "stale" ? " · stale" : "")
                let sub = submenu("\(tags[account.id] ?? "?")  \(account.label) · \(summary)", in: menu)
                section(account, in: sub)
                sub.addItem(.separator())
                sub.addItem(action("Make Primary", #selector(makePrimary(_:)), value: account.id))
                sub.addItem(action("Make Secondary", #selector(makeSecondary(_:)), value: account.id))
            }
        }
        menu.addItem(.separator())
        let primaryMenu = submenu("Primary Account", in: menu)
        let secondaryMenu = submenu("Secondary Account", in: menu)
        secondaryMenu.addItem(action("None", #selector(makeSecondary(_:)), value: "none", checked: secondary == nil))
        for account in accounts {
            let title = account.providerName + " · " + account.label + (account.email.map { " · " + $0 } ?? "")
            primaryMenu.addItem(action(title, #selector(makePrimary(_:)), value: account.id, checked: account.id == primary?.id))
            if account.id != primary?.id {
                secondaryMenu.addItem(action(title, #selector(makeSecondary(_:)), value: account.id, checked: account.id == secondary?.id))
            }
        }
        let bar = submenu("Menu Bar", in: menu)
        func group(_ title: String, key: String, selected: String, options: [(String, String)]) {
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            heading.isEnabled = false; bar.addItem(heading)
            for (title, value) in options {
                bar.addItem(action(title, #selector(setPreference(_:)), value: [key, value], checked: value == selected))
            }
        }
        group("Accounts", key: "barAccounts", selected: preferences.accounts.rawValue,
              options: [("Primary only", "primary"), ("Primary + Secondary", "primarySecondary"), ("All Accounts", "all")])
        bar.addItem(.separator())
        group("Style", key: "barStyle", selected: preferences.style.rawValue,
              options: [("Percent", "percent"), ("Battery", "battery"), ("HP Bar", "hp"), ("Dual Bars", "dual"), ("Ring", "ring")])
        bar.addItem(.separator())
        group("Metric", key: "barMetric", selected: preferences.metric.rawValue,
              options: [("5-Hour", "five"), ("Weekly", "seven"), ("Both", "both"), ("Most Used", "max")])
        bar.addItem(.separator())
        bar.addItem(action("Show Numbers", #selector(togglePreference(_:)), value: "barNumbers", checked: preferences.numbers))
        bar.addItem(action("Always Show in Menu Bar", #selector(togglePreference(_:)), value: "menuBarAlways", checked: preferences.always))
        let widget = submenu("Widget", in: menu)
        for (title, value) in [("Primary only", "primary"), ("Primary + Secondary", "primarySecondary")] {
            widget.addItem(action(title, #selector(setPreference(_:)), value: ["widgetAccounts", value],
                                  checked: preferences.twoWidgets == (value == "primarySecondary")))
        }
        menu.addItem(action(panel?.isVisible == true ? "Minimize to Menu Bar" : "Show Widget",
                            panel?.isVisible == true ? #selector(minimizeToMenuBar) : #selector(restoreFromMenuBar)))
        menu.addItem(action("Refresh Now", #selector(refreshNow)))
        let hasCodex = accounts.contains { $0.isCodex }
        menu.addItem(action(hasCodex ? "Claude Usage Settings…" : "Usage Settings…", #selector(openUsageSettings)))
        if hasCodex { menu.addItem(action("Codex Usage Settings…", #selector(openCodexUsageSettings))) }
        let login = submenu("This Mac's Login", in: menu)
        if accounts.contains(where: { !$0.isCodex && $0.machine_login }) {
            login.addItem(action("Switch Account…", #selector(startLogin)))
            login.addItem(action("Sign Out", #selector(confirmSignOut)))
        } else { login.addItem(action("Sign In to Claude…", #selector(startLogin))) }
        menu.addItem(.separator())
        menu.addItem(action("Quit Claude Usage", #selector(quit)))
        return menu
    }
    @objc func makePrimary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, accounts.contains(where: { $0.id == id }) else { return }
        let old = preferences.primary(in: accounts)?.id
        if preferences.secondaryID == id { UserDefaults.standard.set(old ?? "none", forKey: "secondaryAccount") }
        UserDefaults.standard.set(id, forKey: "primaryAccount")
        updateUI()
    }
    @objc func makeSecondary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != preferences.primary(in: accounts)?.id else { return }
        UserDefaults.standard.set(id, forKey: "secondaryAccount")
        updateUI()
    }
    @objc func setPreference(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        UserDefaults.standard.set(pair[1], forKey: pair[0]); updateUI()
    }
    @objc func togglePreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(sender.state != .on, forKey: key); updateUI()
    }

    @objc func refreshNow() {
        guard !refreshing else { refreshPending = true; return }
        guard !accounts.isEmpty else { refresh(); return }
        refreshing = true
        let group = DispatchGroup()
        for account in accounts {
            var components = URLComponents(string: baseURL + "/api/refresh")!
            components.queryItems = [URLQueryItem(name: "account", value: account.id)]
            group.enter()
            post(to: components.url!) { _ in group.leave() }
        }
        group.notify(queue: .main) { self.refreshing = false; self.refreshPending = false; self.refresh() }
    }
    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        var request = URLRequest(url: URL(string: baseURL + "/api/accounts")!)
        request.timeoutInterval = 100
        URLSession.shared.dataTask(with: request) { data, response, _ in
            // Only a missing route means an old server. Network/decode failures
            // must never silently replace the registry with a single login.
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                self.refreshLegacy(); return
            }
            let result = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap { try? JSONDecoder().decode(AccountsResponse.self, from: $0) } : nil
            DispatchQueue.main.async { self.receive(result?.accounts) }
        }.resume()
    }
    func receive(_ fresh: [UsageAccount]?) {
        refreshing = false
        if let fresh {
            failCount = 0
            for account in fresh where account.state == "ok" {
                if let old = previous[account.id], old.state == "ok" {
                    func reset(_ before: LimitInfo?, _ after: LimitInfo?) -> Bool {
                        guard let before, let after, before.value != nil, after.value != nil else { return false }
                        if let oldDate = before.resets_at.flatMap(parseISO) {
                            if let newDate = after.resets_at.flatMap(parseISO) { return newDate > oldDate }
                            return after.value == 0 && oldDate <= Date()
                        }
                        return false
                    }
                    if reset(old.five_hour, account.five_hour) || reset(old.seven_day, account.seven_day) {
                        danceEnds[account.id] = Date().addingTimeInterval(8)
                    }
                }
                previous[account.id] = account
            }
            accounts = fresh
            if preferences.primaryID == nil, let primary = preferences.primary(in: fresh) {
                UserDefaults.standard.set(primary.id, forKey: "primaryAccount")
            }
        } else {
            failCount += 1
            // Keep the snapshot visibly stale from the first transport failure.
            accounts = accounts.map { var a = $0; if a.state == "ok" { a.state = "stale" }; return a }
        }
        updateUI()
        if refreshPending { refreshPending = false; refreshNow() }
    }
    func refreshLegacy() {
        URLSession.shared.dataTask(with: URL(string: baseURL + "/api/usage")!) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let usage = try? JSONDecoder().decode(Usage.self, from: data) else {
                DispatchQueue.main.async { self.receive(nil) }; return
            }
            URLSession.shared.dataTask(with: URL(string: baseURL + "/api/account")!) { data, _, _ in
                guard let data, let account = try? JSONDecoder().decode(AccountInfo.self, from: data) else {
                    DispatchQueue.main.async { self.receive(nil) }; return
                }
                var items: [UsageAccount] = []
                if account.logged_in && usage.logged_in != false {
                    items = [UsageAccount(id: "machine", label: account.name ?? "This Mac", email: account.email,
                                          plan: account.plan, source: "keychain", machine_login: true,
                                          five_hour: usage.five_hour, seven_day: usage.seven_day,
                                          limits: usage.limits, fetched_at: usage.fetched_at)]
                }
                let result = items
                DispatchQueue.main.async { self.receive(result) }
            }.resume()
        }.resume()
    }

    func post(to url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("1", forHTTPHeaderField: "X-Widget")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async { completion((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)) }
        }.resume()
    }
    @objc func startLogin() {
        post(to: URL(string: baseURL + "/api/login")!) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.showAuthError("Could not start Claude sign in."); return }
            self.refresh()
            self.switchWatch?.invalidate()
            let deadline = Date().addingTimeInterval(180)
            self.switchWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                if Date() >= deadline { timer.invalidate(); return }
                self?.refresh()
            }
        }
    }
    @objc func confirmSignOut() {
        let email = accounts.first(where: { $0.machine_login })?.email ?? "the current account"
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
        post(to: URL(string: baseURL + "/api/logout")!) { [weak self] ok in
            if ok { self?.refresh() } else { self?.showAuthError("Could not sign out of Claude Code.") }
        }
    }
    func showAuthError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message
        alert.informativeText = "Make sure the local usage server and Claude Code are installed."
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc func openUsageSettings() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc func openCodexUsageSettings() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func ensureServer() {
        URLSession.shared.dataTask(with: URL(string: baseURL + "/api/ping")!) { data, _, _ in
            guard data == nil else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [widgetDir + "/server.py"]
            process.standardOutput = nil; process.standardError = nil
            try? process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        }.resume()
    }
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1].hasPrefix("--preview-") {
    guard CommandLine.arguments.count >= 3 else { exit(2) }
    exit(renderPreview(kind: CommandLine.arguments[1], path: CommandLine.arguments[2],
                       dark: CommandLine.arguments.contains("--dark"),
                       signedOut: CommandLine.arguments.contains("--signed-out"),
                       two: CommandLine.arguments.contains("--two")))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

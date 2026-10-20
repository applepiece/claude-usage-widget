import Cocoa
import UsageKit

@MainActor
extension AppDelegate {
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
        for item in UsageMenuViews.items(account: account.info, usage: usage, role: role, state: account.rawState) {
            menu.addItem(item)
        }
        if account.state == .tokenRejected {
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
            for item in UsageMenuViews.items(account: AccountInfo(loggedIn: false), usage: nil) { menu.addItem(item) }
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
                let summary = account.failed ? account.rawState.replacingOccurrences(of: "_", with: " ")
                    : "5H \(percentage(account.fiveHour)) · WK \(percentage(account.sevenDay))" + (account.state == .stale ? " · stale" : "")
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
        if accounts.contains(where: { !$0.isCodex && $0.machineLogin }) {
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
        if preferences.secondaryID == id { preferences.defaults.set(old ?? "none", forKey: "secondaryAccount") }
        preferences.defaults.set(id, forKey: "primaryAccount")
        updateUI()
    }
    @objc func makeSecondary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != preferences.primary(in: accounts)?.id else { return }
        preferences.defaults.set(id, forKey: "secondaryAccount")
        updateUI()
    }
    @objc func setPreference(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        preferences.defaults.set(pair[1], forKey: pair[0]); updateUI()
    }
    @objc func togglePreference(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        preferences.defaults.set(sender.state != .on, forKey: key); updateUI()
    }

}

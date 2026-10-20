import Cocoa
import UsageKit

@MainActor
extension AppDelegate: NSMenuDelegate {
    func action(_ title: String, _ selector: Selector, value: Any? = nil,
                checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        return item
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 300
        menu.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        menu.delegate = self
        let now = Date()
        for item in UsageMenuViews.items(account: model.primary, now: now) { menu.addItem(item) }
        if accounts.isEmpty {
            menu.addItem(action(String(localized: "Sign In to Claude…"), #selector(startLogin)))
        }
        menu.addItem(.separator())
        if accounts.count >= 2 {
            let ordered = accounts.filter { !$0.isCodex } + accounts.filter { $0.isCodex }
            for account in ordered {
                let item = action(account.label, #selector(makePrimary(_:)), value: account.id,
                                  checked: account.id == model.primary?.id)
                item.attributedTitle = AccountMenuTitle.make(account)
                let isSecondary = account.id == model.secondary?.id
                var detail = MenuFormatting.accountTooltip(account, now: now)
                if isSecondary {
                    item.state = .mixed
                    if let symbol = NSImage(systemSymbolName: "2.circle", accessibilityDescription: String(localized: "Secondary account"))?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) {
                        symbol.isTemplate = true
                        symbol.size = NSSize(width: 12, height: 12)
                        item.mixedStateImage = symbol
                    }
                    detail += " · " + String(localized: "Secondary account")
                }
                item.toolTip = detail
                item.setAccessibilityLabel(detail)
                item.setAccessibilityHelp(detail)
                menu.addItem(item)
                let alternateTitle = isSecondary
                    ? String(localized: "Stop Using \(account.label) as Secondary")
                    : String(localized: "Use \(account.label) as Secondary")
                let alternate = action(alternateTitle, #selector(makeSecondary(_:)), value: isSecondary ? "none" : account.id)
                alternate.attributedTitle = AccountMenuTitle.alternate(alternateTitle)
                alternate.toolTip = alternateTitle + " · " + detail
                alternate.setAccessibilityLabel(alternateTitle + " · " + detail)
                alternate.isAlternate = true
                alternate.keyEquivalentModifierMask = .option
                alternate.isEnabled = account.id != model.primary?.id
                menu.addItem(alternate)
            }
            menu.addItem(.separator())
        }
        menu.addItem(action(String(localized: "Show Widget"), #selector(toggleWidget), checked: model.widgetVisible))
        let refresh = action(model.refreshing ? String(localized: "Refreshing…") : String(localized: "Refresh"),
                             #selector(refreshNow))
        refresh.identifier = NSUserInterfaceItemIdentifier("refresh")
        refresh.isEnabled = !model.refreshing
        menu.addItem(refresh)
        menu.addItem(action(String(localized: "Settings…"), #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "Quit"), #selector(quit)))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackingMenu = menu
        if qa.enabled, qa.open == "menu", !qaReadySent {
            // Common mode runs after AppKit has laid out and displayed the tracking menu.
            let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(announceQAReady), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if trackingMenu === menu { trackingMenu = nil }
    }

    func updateRefreshMenuItem() {
        guard let item = trackingMenu?.items.first(where: { $0.identifier?.rawValue == "refresh" }) else { return }
        item.attributedTitle = nil
        item.title = model.refreshing ? String(localized: "Refreshing…") : String(localized: "Refresh")
        item.isEnabled = !model.refreshing
    }

    @objc func makePrimary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.makePrimary(id)
        updateUI()
    }
    @objc func makeSecondary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setSecondary(id)
        updateUI()
    }
    @objc func toggleWidget() { model.setWidgetVisible(!model.widgetVisible) }
    @objc func openSettings() { showSettings() }

    func showSettings(tab: SettingsTab? = nil) {
        if settingsController == nil { settingsController = SettingsWindowController(model: model) }
        settingsController?.show(tab: tab)
    }

    func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let actions = NSMenu()
        actions.addItem(action(String(localized: "Settings…"), #selector(openSettings), key: ","))
        actions.addItem(action(String(localized: "Refresh"), #selector(refreshNow), key: "r"))
        actions.addItem(.separator())
        actions.addItem(action(String(localized: "Quit Claude Usage"), #selector(quit), key: "q"))
        application.submenu = actions
        main.addItem(application)
        let window = NSMenuItem()
        window.title = String(localized: "Window")
        let windows = NSMenu(title: String(localized: "Window"))
        windows.addItem(NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.submenu = windows
        main.addItem(window)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }
}

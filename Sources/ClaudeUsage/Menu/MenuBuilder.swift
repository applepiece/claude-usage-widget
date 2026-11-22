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

    func buildMenu(now: Date = Date()) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 300
        menu.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        menu.delegate = self
        for item in UsageMenuViews.items(account: model.primary, now: now) { menu.addItem(item) }
        if accounts.isEmpty {
            menu.addItem(action(String(localized: "Sign In to Claude…"), #selector(startLogin)))
        }
        let accountAnchor = NSMenuItem.separator()
        accountAnchor.identifier = NSUserInterfaceItemIdentifier("accounts.anchor")
        menu.addItem(accountAnchor)
        updateAccountMenu(in: menu, now: now)
        let widget = action(String(localized: "Show Widget"), #selector(toggleWidget), checked: model.widgetVisible)
        widget.identifier = NSUserInterfaceItemIdentifier("widget")
        menu.addItem(widget)
        updateCreditsMenu(in: menu, now: now)
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

    func updateAccountMenu(in menu: NSMenu, now: Date = Date()) {
        if trackingMenu === menu,
           let caption = menu.items.first(where: { $0.identifier?.rawValue == "accounts.row.caption" }),
           let state = caption.representedObject as? AccountMenuState, state == preferences.accountMenuState {
            return
        }
        for item in menu.items where item.identifier?.rawValue.hasPrefix("accounts.row.") == true {
            menu.removeItem(item)
        }
        guard accounts.count >= 2,
              let anchor = menu.items.first(where: { $0.identifier?.rawValue == "accounts.anchor" }) else { return }
        let slots = preferences.barSlots
        var index = menu.index(of: anchor) + 1
        func insert(_ item: NSMenuItem, id: String) {
            item.identifier = NSUserInterfaceItemIdentifier("accounts.row." + id)
            menu.insertItem(item, at: index)
            index += 1
        }
        let caption = NSMenuItem(title: String(localized: "Usage bars"), action: nil, keyEquivalent: "")
        caption.isEnabled = false
        caption.attributedTitle = AccountMenuTitle.caption(slots: slots)
        caption.representedObject = preferences.accountMenuState
        caption.setAccessibilityLabel(slots.map(\.title).joined(separator: ", "))
        insert(caption, id: "caption")
        let ordered = accounts.filter { !$0.isCodex } + accounts.filter { $0.isCodex }
        for account in ordered {
            let item = action(account.label, #selector(makePrimary(_:)), value: account.id,
                              checked: account.id == model.primary?.id)
            item.attributedTitle = AccountMenuTitle.make(account, slots: slots)
            let isSecondary = account.id == model.secondary?.id
            var detail = MenuFormatting.accountTooltip(account, now: now, slots: slots)
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
            insert(item, id: account.id)
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
            insert(alternate, id: "alternate." + account.id)
        }
        insert(.separator(), id: "separator")
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackingMenu = menu
        refreshCredits()
        if qa.enabled, qa.open == "menu", !qaReadySent {
            // Common mode runs after AppKit has laid out and displayed the tracking menu.
            let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(announceQAReady), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if trackingMenu === menu { trackingMenu = nil }
    }

    func updateCreditsMenu(in menu: NSMenu, now: Date = Date()) {
        let currentHeader = menu.items.first { $0.identifier?.rawValue == "credits.header" }
        let currentStructure = currentHeader?.representedObject as? CreditMenuStructure
        // A display-mode change takes effect on the next open, preserving the tracked submenu.
        let display = trackingMenu === menu ? (currentStructure?.display ?? preferences.creditsDisplay) : preferences.creditsDisplay
        let presentation = CreditsMenuPresentation(providers: model.credits, display: display,
                                                  updatedAt: model.creditsUpdatedAt, now: now,
                                                  warnDays: preferences.creditsWarnDays)
        let amountColumnWidth = CreditMenuTitle.amountColumnWidth(presentation)
        if let header = currentHeader, currentStructure == presentation.structure {
            updateCreditHeader(header, presentation: presentation)
            let providerMenu = presentation.display == .total ? header.submenu : menu
            for row in presentation.rows {
                if let item = providerMenu?.items.first(where: { $0.identifier?.rawValue == "credits.provider." + row.provider.id }) {
                    updateCreditProviderItem(item, row: row, amountColumnWidth: amountColumnWidth)
                }
            }
            if let warning = menu.items.first(where: { $0.identifier?.rawValue == "credits.warning" }) {
                updateCreditWarning(warning, title: presentation.warning)
            }
            return
        }
        for item in menu.items where item.identifier?.rawValue.hasPrefix("credits.") == true {
            menu.removeItem(item)
        }
        guard presentation.showsSection,
              let widget = menu.items.first(where: { $0.identifier?.rawValue == "widget" }) else { return }
        var index = menu.index(of: widget)
        func insert(_ item: NSMenuItem, id: String) {
            item.identifier = NSUserInterfaceItemIdentifier("credits." + id)
            menu.insertItem(item, at: index)
            index += 1
        }
        let header = NSMenuItem(title: String(localized: "API credits"), action: nil, keyEquivalent: "")
        updateCreditHeader(header, presentation: presentation)
        if presentation.display == .total {
            let providers = NSMenu(title: header.title)
            providers.autoenablesItems = false
            for row in presentation.rows {
                providers.addItem(creditProviderItem(row, amountColumnWidth: amountColumnWidth))
            }
            header.submenu = providers
        }
        insert(header, id: "header")
        for row in presentation.mainRows {
            insert(creditProviderItem(row, amountColumnWidth: amountColumnWidth), id: "provider." + row.provider.id)
        }
        // Keep this item even when hidden so a new warning cannot reset native menu tracking.
        let warning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updateCreditWarning(warning, title: presentation.warning)
        insert(warning, id: "warning")
        insert(.separator(), id: "separator")
    }

    private func updateCreditHeader(_ item: NSMenuItem, presentation: CreditsMenuPresentation) {
        item.isEnabled = presentation.display == .total
        item.attributedTitle = CreditMenuTitle.header(total: presentation.totalAmount)
        item.setAccessibilityLabel(item.title + " · " + presentation.totalAmount)
        item.representedObject = presentation.structure
    }

    private func updateCreditWarning(_ item: NSMenuItem, title: String?) {
        item.title = title ?? ""
        item.isEnabled = false
        item.isHidden = title == nil
        item.attributedTitle = title.map(CreditMenuTitle.warning)
        item.setAccessibilityLabel(title)
    }

    private func creditProviderItem(_ row: CreditRowPresentation, amountColumnWidth: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: row.shortLabel, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("credits.provider." + row.provider.id)
        updateCreditProviderItem(item, row: row, amountColumnWidth: amountColumnWidth)
        return item
    }

    private func updateCreditProviderItem(_ item: NSMenuItem, row: CreditRowPresentation, amountColumnWidth: CGFloat) {
        let provider = row.provider
        item.title = row.shortLabel
        item.attributedTitle = CreditMenuTitle.make(provider, row: row, amountColumnWidth: amountColumnWidth)
        item.toolTip = row.detail
        item.setAccessibilityLabel(row.detail)
        item.setAccessibilityHelp(provider.note)
        let details = item.submenu ?? NSMenu(title: row.shortLabel)
        if item.submenu == nil { item.submenu = details }
        details.title = row.shortLabel
        details.autoenablesItems = false
        let detailIDs = Set(row.detailItems.indices.map { "credits.detail." + String($0) })
        for detail in details.items {
            if let id = detail.identifier?.rawValue, id.hasPrefix("credits.detail."), !detailIDs.contains(id) {
                details.removeItem(detail)
            }
        }
        for (index, title) in row.detailItems.enumerated() {
            let id = NSUserInterfaceItemIdentifier("credits.detail." + String(index))
            if let detail = details.items.first(where: { $0.identifier == id }) {
                detail.title = title
            } else {
                let detail = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                detail.identifier = id
                detail.isEnabled = false
                details.insertItem(detail, at: index)
            }
        }
        if !details.items.contains(where: \.isSeparatorItem) { details.addItem(.separator()) }
        let console: NSMenuItem
        if let existing = details.items.first(where: { $0.identifier?.rawValue == "credits.console" }) {
            console = existing
        } else {
            console = action(String(localized: "Open Billing Console…"), #selector(openCreditsConsole(_:)))
            console.identifier = NSUserInterfaceItemIdentifier("credits.console")
            details.addItem(console)
        }
        console.representedObject = provider.console
        console.isEnabled = provider.consoleURL != nil
    }

    @objc func openCreditsConsole(_ sender: NSMenuItem) {
        guard let url = CreditFormatting.consoleURL(sender.representedObject as? String) else { return }
        NSWorkspace.shared.open(url)
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
        updateUI(persistWidgetResize: true)
    }
    @objc func makeSecondary(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setSecondary(id)
        updateUI(persistWidgetResize: true)
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

import Cocoa
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, menuBar, accounts, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .menuBar: String(localized: "Menu Bar")
        case .accounts: String(localized: "Accounts")
        case .about: String(localized: "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .accounts: "person.2"
        case .about: "info.circle"
        }
    }
}

@MainActor
private final class SettingsTabsController: NSTabViewController {
    var selectionChanged: ((SettingsTab) -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tab = SettingsTab(rawValue: selectedTabViewItemIndex) else { return }
        selectionChanged?(tab)
    }
}

/// A grouped Form is scrollable and has no intrinsic height. Measure its content
/// separately, then cap the native window to the available screen height.
private struct SettingsHeightKey: PreferenceKey {
    static let defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = value.union(nextValue()) }
}

extension View {
    func measureSettingsSection() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: SettingsHeightKey.self, value: geometry.frame(in: .named("settingsForm")))
        })
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let tabs = SettingsTabsController()
    private var heights: [SettingsTab: CGFloat] = [:]
    private var firstOpen = true
    private var restoredPosition = false
    private var centerAfterFirstMeasurement = false
    private var selected: SettingsTab = .general

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = SettingsTab.general.title
        super.init(window: window)
        if !model.isQA {
            restoredPosition = window.setFrameUsingName("ClaudeUsage.Settings")
            window.setFrameAutosaveName("ClaudeUsage.Settings")
        }
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for tab in SettingsTab.allCases {
            let content = SettingsContent(tab: tab, model: model)
                .defaultAppStorage(model.preferences.defaults)
                .frame(width: 480)
                .onPreferenceChange(SettingsHeightKey.self) { [weak self] bounds in
                    guard !bounds.isNull, bounds.height.isFinite else { return }
                    Task { @MainActor [weak self] in self?.contentMeasured(bounds.height, tab: tab) }
                }
            let host = NSHostingController(rootView: content)
            // The window controls sizing; the SwiftUI scroll view fills it.
            host.sizingOptions = []
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectionChanged = { [weak self] tab in self?.select(tab) }
        window.contentViewController = tabs
    }

    required init?(coder: NSCoder) { nil }

    func show(tab: SettingsTab? = nil) {
        guard let window else { return }
        let tab = tab ?? selected
        tabs.selectedTabViewItemIndex = tab.rawValue
        select(tab)
        if firstOpen {
            if !restoredPosition {
                window.center()
                centerAfterFirstMeasurement = heights[tab] == nil
            }
            firstOpen = false
        }
        if model.isQA { window.orderFrontRegardless() }
        else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func contentMeasured(_ height: CGFloat, tab: SettingsTab) {
        guard height > 0 else { return }
        // Native grouped forms use section gaps and outer margins. The measured
        // sections include their headers/footers; allow the default outer inset.
        let desired = ceil(height + 40)
        guard abs((heights[tab] ?? 0) - desired) > 1 else { return }
        heights[tab] = desired
        if selected == tab {
            resize(animated: window?.isVisible == true)
            if centerAfterFirstMeasurement {
                window?.center()
                centerAfterFirstMeasurement = false
            }
        }
    }

    private func select(_ tab: SettingsTab) {
        selected = tab
        window?.title = tab.title
        resize(animated: window?.isVisible == true)
    }

    private func resize(animated: Bool) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let chrome = window.frame.height - window.contentLayoutRect.height
        let maximum = max(240, (visible?.height ?? 900) - chrome - 40)
        let height = min(heights[selected] ?? 360, maximum)
        // Include the toolbar above the 480 pt wide SwiftUI form and preserve
        // the window's top edge while animating between tabs.
        var frame = window.frame
        let newHeight = height + chrome
        frame.origin.y += frame.height - newHeight
        frame.size = NSSize(width: 480, height: newHeight)
        if let visible, frame.minY < visible.minY { frame.origin.y = visible.minY }
        window.setFrame(frame, display: true,
                        animate: animated && !model.isQA && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

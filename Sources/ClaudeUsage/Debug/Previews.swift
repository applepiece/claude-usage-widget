import Cocoa
import UsageKit

@MainActor
func sampleCredits(now: Date = Date()) -> [CreditProvider] {
    let anchor = UsageFormatting.iso.string(from: now)
    return [
        CreditProvider(id: "anthropic", label: "Claude API", remaining: 199.95, granted: 200,
                       spentSinceAnchor: 0.05, anchorAt: anchor,
                       nextExpiry: CreditExpiry(date: UsageFormatting.iso.string(from: now.addingTimeInterval(18 * 86400)), amount: 200),
                       console: "https://platform.claude.com/settings/billing", extra: 9.07),
        CreditProvider(id: "openai", label: "OpenAI API", remaining: 5.25, granted: 100,
                       spentSinceAnchor: 94.75, spendSource: .costsAPI, anchorAt: anchor,
                       nextExpiry: CreditExpiry(date: UsageFormatting.iso.string(from: now.addingTimeInterval(2 * 86400)), amount: 5.25),
                       console: "https://platform.openai.com/settings/organization/billing/credit-grants"),
    ]
}

// Development-only offscreen rendering. No window, panel, status item, app
// launch callback, login registration or network request is created here.
@MainActor
func sampleAccounts() -> [UsageAccount] {
    func limit(_ value: Double, hours: Double) -> LimitInfo {
        LimitInfo(utilization: value, resetsAt: UsageFormatting.iso.string(from: Date().addingTimeInterval(hours * 3600)))
    }
    return [
        UsageAccount(id: "pho", label: "pho", email: "kriengkrai.pho@gmail.com", plan: "max",
                     source: "keychain", machineLogin: true, fiveHour: limit(15, hours: 3),
                     sevenDay: limit(82, hours: 96), fetchedAt: Date().timeIntervalSince1970, provider: .claude),
        UsageAccount(id: "kkpk", label: "kkpk", email: "kkpk@example.com", plan: "max",
                     fiveHour: limit(0, hours: 5), sevenDay: limit(37, hours: 120),
                     fetchedAt: Date().timeIntervalSince1970, provider: .claude),
        UsageAccount(id: "mahidol", label: "mahidol", email: "mahidol@example.com", plan: "team",
                     fiveHour: limit(4, hours: 4), fetchedAt: Date().timeIntervalSince1970, provider: .claude),
        UsageAccount(id: "codex-pro", label: "pro", email: "pro@example.com", plan: "pro lite",
                     source: "codex", sevenDay: limit(12, hours: 96), fetchedAt: Date().timeIntervalSince1970,
                     provider: .codex, asOf: Date().timeIntervalSince1970 - 120, quotaSource: "live"),
        UsageAccount(id: "codex-edu", label: "edu", email: "edu@example.com", plan: "edu",
                     source: "codex", fiveHour: limit(1, hours: 4), sevenDay: limit(0, hours: 168),
                     fetchedAt: Date().timeIntervalSince1970, provider: .codex,
                     asOf: Date().timeIntervalSince1970, quotaSource: "live"),
    ]
}

@MainActor
final class PreviewCanvas: NSView {
    var statusRows: [(String, StatusTitle)] = []
    var transparent = false
    override func draw(_ dirtyRect: NSRect) {
        if !transparent { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        for (index, row) in statusRows.enumerated() {
            let y = bounds.height - CGFloat(index + 1) * 32
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 0, y: y + 4, width: bounds.width, height: 24).fill()
            (row.0 as NSString).draw(at: NSPoint(x: 10, y: y + 8),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.labelColor])
            StatusRenderer.drawPreview(row.1, in: NSRect(x: 220, y: y + 4,
                                                       width: StatusRenderer.previewSize(row.1).width, height: 24))
        }
    }
}

/// Approximates only native menu rows; the card uses its actual custom views.
@MainActor
private final class MenuPreviewRow: NSView {
    let item: NSMenuItem

    init(item: NSMenuItem, frame: NSRect) {
        self.item = item
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 13)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: item.isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let title = item.attributedTitle ?? NSAttributedString(string: item.title, attributes: attributes)
        title.draw(in: NSRect(x: AccountMenuTitle.titleInset, y: 4, width: AccountMenuTitle.weeklyTab, height: bounds.height - 8))
        if item.state == .on {
            NSAttributedString(string: "✓", attributes: attributes).draw(at: NSPoint(x: 6, y: 4))
        } else if item.state == .mixed {
            item.mixedStateImage?.draw(in: NSRect(x: 6, y: 6, width: 12, height: 12))
        }
        if !item.keyEquivalent.isEmpty {
            let key = NSAttributedString(string: "⌘" + item.keyEquivalent.uppercased(), attributes: attributes)
            key.draw(at: NSPoint(x: bounds.width - 14 - key.size().width, y: 4))
        }
    }
}

@MainActor
func writePreview(_ canvas: NSView, path: String) -> Int32 {
    canvas.layoutSubtreeIfNeeded()
    guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return 1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
        canvas.displayIgnoringOpacity(canvas.bounds, in: context)
        @MainActor func children(_ parent: NSView) {
            for view in parent.subviews where !view.isHidden {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: view.frame.minX, yBy: view.frame.minY)
                transform.concat()
                view.displayIgnoringOpacity(view.bounds, in: context)
                children(view)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        children(canvas)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return 1 }
    do { try data.write(to: URL(fileURLWithPath: path)); return 0 } catch { return 1 }
}

@MainActor
func renderPreview(kind: String, path: String, dark: Bool, signedOut: Bool, two: Bool) -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    registerPixelFont()
    guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return 1 }
    let samples = sampleAccounts()
    let canvas: PreviewCanvas
    switch kind {
    case "--preview-statusbar":
        canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 580, height: 16 * 32))
        let names = AccountShortNames.effective(in: samples, custom: [:])
        for mode in BarAccounts.allCases {
            for metric in BarMetric.allCases {
                let shown: [UsageAccount] = mode == .all ? samples : (mode == .primarySecondary ? [samples[0], samples[3]] : [samples[0]])
                let title = StatusTitle(accounts: shown, shortNames: names, metric: metric, numbers: true)
                canvas.statusRows.append((mode.rawValue + " · " + metric.rawValue, title))
            }
        }
        var error = samples[0]; error.state = .tokenRejected
        canvas.statusRows.append(("token rejected", StatusTitle(accounts: [error], shortNames: names)))
        var rejected = samples; rejected[4].state = .tokenRejected
        canvas.statusRows.append(("all · codex rejected", StatusTitle(accounts: rejected, shortNames: names)))
        canvas.statusRows.append(("six Thai characters", StatusTitle(
            accounts: [samples[0]], shortNames: ["pho": "กิขีคุฆูง่จ้"])))
        canvas.statusRows.append(("percentage off", StatusTitle(accounts: samples, numbers: false)))
    case "--preview-widget":
        canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 216, height: two ? 148 : 74))
        canvas.transparent = true
        let shownSamples: [UsageAccount] = two ? [samples[0], samples[3]] : [samples[0]]
        for (index, account) in shownSamples.enumerated() {
            let widget = WidgetView(frame: NSRect(x: 0, y: canvas.bounds.height - CGFloat(index + 1) * 74,
                                                  width: 216, height: 74))
            widget.accountTag = two ? (accountTags(samples)[account.id] ?? "") : ""
            widget.showsMascot = index == 0
            widget.nightOverride = false
            widget.offline = false
            widget.five = account.fiveHour?.value.map { ($0, "14:00") }
            widget.seven = account.sevenDay?.value.map { ($0, "FRI 14:00") }
            canvas.addSubview(widget)
        }
    case "--preview-menu":
        // Registration defaults are volatile: previewing never changes the
        // user's selected accounts or their saved menu preferences.
        guard let defaults = UserDefaults(suiteName: "ClaudeUsage.preview." + UUID().uuidString) else { return 1 }
        defaults.register(defaults: ["primaryAccount": "pho", "secondaryAccount": "codex-pro"])
        let delegate = AppDelegate(preferences: Preferences(defaults))
        delegate.accounts = signedOut ? [] : samples
        delegate.model.creditSnapshot = CreditSnapshot(providers: sampleCredits(), updatedAt: Date())
        delegate.model.lastUpdate = delegate.accounts.compactMap(MenuFormatting.timestamp).max()
        delegate.model.widgetVisible = true
        var menu = NSMenu()
        // Resolve attachment colors in the requested preview appearance.
        appearance.performAsCurrentDrawingAppearance { menu = delegate.buildMenu() }
        let items = menu.items.filter { !$0.isAlternate }
        let heights: [CGFloat] = items.map {
            $0.view?.frame.height ?? ($0.isSeparatorItem ? 10 : max(24, ceil($0.attributedTitle?.size().height ?? 16) + 8))
        }
        let height = heights.reduce(16, +)
        canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        var y = height - 8
        for (index, item) in items.enumerated() {
            y -= heights[index]
            if let view = item.view {
                item.view = nil
                view.frame.origin = NSPoint(x: 0, y: y)
                canvas.addSubview(view)
            } else if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: 14, y: y + 4, width: 272, height: 1))
                line.boxType = .separator; canvas.addSubview(line)
            } else {
                canvas.addSubview(MenuPreviewRow(item: item, frame: NSRect(x: 0, y: y, width: 300, height: heights[index])))
            }
        }
    default: return 2
    }
    canvas.appearance = appearance
    return writePreview(canvas, path: path)
}

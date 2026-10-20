import Cocoa
import UsageKit

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
    var statusRows: [(String, NSImage)] = []
    var transparent = false
    override func draw(_ dirtyRect: NSRect) {
        if !transparent { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        for (index, row) in statusRows.enumerated() {
            let y = bounds.height - CGFloat(index + 1) * 32
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: 30).fill()
            (row.0 as NSString).draw(at: NSPoint(x: 10, y: y + 8),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.labelColor])
            row.1.draw(in: NSRect(x: 190, y: y + 4, width: row.1.size.width, height: 22))
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
        canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 370, height: 17 * 32))
        for style in BarStyle.allCases {
            for mode in BarAccounts.allCases {
                let shown: [UsageAccount] = mode == .all ? samples : (mode == .primarySecondary ? [samples[0], samples[3]] : [samples[0]])
                let image = StatusRenderer.image(accounts: shown, tags: accountTags(samples),
                                                 style: style, metric: .max, numbers: true, appearance: appearance)
                canvas.statusRows.append((style.rawValue + " · " + mode.rawValue, image))
            }
        }
        var error = samples[0]; error.state = .tokenRejected
        canvas.statusRows.append(("battery · token rejected", StatusRenderer.image(
            accounts: [error], tags: accountTags(samples), style: .battery, metric: .max,
            numbers: true, appearance: appearance)))
        var rejected = samples; rejected[4].state = .tokenRejected
        canvas.statusRows.append(("battery · all · codex rejected", StatusRenderer.image(
            accounts: rejected, tags: accountTags(samples), style: .battery, metric: .max,
            numbers: true, appearance: appearance)))
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
        delegate.model.lastUpdate = delegate.accounts.compactMap(MenuFormatting.timestamp).max()
        delegate.model.widgetVisible = true
        let menu = delegate.buildMenu()
        let items = menu.items.filter { !$0.isAlternate }
        func subtitle(_ item: NSMenuItem) -> String? {
            if #available(macOS 14.4, *) { return item.subtitle }
            return item.attributedTitle?.string.split(separator: "\n").dropFirst().first.map(String.init)
        }
        let heights: [CGFloat] = items.map {
            $0.view?.frame.height ?? ($0.isSeparatorItem ? 10 : (subtitle($0) == nil ? 24 : 40))
        }
        let height = heights.reduce(16, +)
        canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 316, height: height))
        var y = height - 8
        for (index, item) in items.enumerated() {
            y -= heights[index]
            if let view = item.view {
                item.view = nil
                view.frame.origin = NSPoint(x: 8, y: y)
                canvas.addSubview(view)
            } else if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: 22, y: y + 4, width: 272, height: 1))
                line.boxType = .separator; canvas.addSubview(line)
            } else {
                // Standard AppKit rows are approximated only in the PNG preview.
                let title = item.title.split(separator: "\n").first.map(String.init) ?? ""
                let text = (item.state == .on ? "✓ " : "") + title
                let label = NSTextField(labelWithString: text)
                label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                label.textColor = item.isSectionHeader || !item.isEnabled ? .secondaryLabelColor : .labelColor
                let x: CGFloat = item.image == nil ? 22 : 50
                label.frame = NSRect(x: x, y: y + heights[index] - 21, width: 294 - x, height: 18)
                label.lineBreakMode = .byTruncatingTail
                canvas.addSubview(label)
                if let image = item.image {
                    let avatar = NSImageView(frame: NSRect(x: 22, y: y + 10, width: 20, height: 20))
                    avatar.image = image
                    canvas.addSubview(avatar)
                }
                if let detail = subtitle(item) {
                    let caption = NSTextField(labelWithString: detail)
                    caption.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                    caption.textColor = .secondaryLabelColor
                    caption.frame = NSRect(x: x, y: y + 3, width: 294 - x, height: 15)
                    caption.lineBreakMode = .byTruncatingTail
                    canvas.addSubview(caption)
                }
            }
        }
    default: return 2
    }
    canvas.appearance = appearance
    return writePreview(canvas, path: path)
}

import Cocoa

// Development-only offscreen rendering. No window, panel, status item, app
// launch callback, login registration or network request is created here.
func sampleAccounts() -> [UsageAccount] {
    let iso = ISO8601DateFormatter()
    func limit(_ value: Double, hours: Double) -> LimitInfo {
        LimitInfo(utilization: value, resets_at: iso.string(from: Date().addingTimeInterval(hours * 3600)))
    }
    return [
        UsageAccount(id: "pho", label: "pho", email: "kriengkrai.pho@gmail.com", plan: "max",
                     source: "keychain", machine_login: true, five_hour: limit(15, hours: 3),
                     seven_day: limit(82, hours: 96), fetched_at: Date().timeIntervalSince1970, provider: "claude"),
        UsageAccount(id: "kkpk", label: "kkpk", email: "kkpk@example.com", plan: "max",
                     five_hour: limit(0, hours: 5), seven_day: limit(37, hours: 120),
                     fetched_at: Date().timeIntervalSince1970, provider: "claude"),
        UsageAccount(id: "mahidol", label: "mahidol", email: "mahidol@example.com", plan: "team",
                     five_hour: limit(4, hours: 4), fetched_at: Date().timeIntervalSince1970, provider: "claude"),
        UsageAccount(id: "codex-pro", label: "pro", email: "pro@example.com", plan: "pro lite",
                     source: "codex", seven_day: limit(12, hours: 96), fetched_at: Date().timeIntervalSince1970,
                     provider: "codex", as_of: Date().timeIntervalSince1970 - 120, quota_source: "live"),
        UsageAccount(id: "codex-edu", label: "edu", email: "edu@example.com", plan: "edu",
                     source: "codex", five_hour: limit(1, hours: 4), seven_day: limit(0, hours: 168),
                     fetched_at: Date().timeIntervalSince1970, provider: "codex",
                     as_of: Date().timeIntervalSince1970, quota_source: "live"),
    ]
}

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

func writePreview(_ canvas: NSView, path: String) -> Int32 {
    canvas.layoutSubtreeIfNeeded()
    guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return 1 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
        canvas.displayIgnoringOpacity(canvas.bounds, in: context)
        func children(_ parent: NSView) {
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

func renderPreview(kind: String, path: String, dark: Bool, signedOut: Bool, two: Bool) -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    registerPixelFont()
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
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
        var error = samples[0]; error.state = "token_rejected"
        canvas.statusRows.append(("battery · token rejected", StatusRenderer.image(
            accounts: [error], tags: accountTags(samples), style: .battery, metric: .max,
            numbers: true, appearance: appearance)))
        var rejected = samples; rejected[4].state = "token_rejected"
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
            widget.five = account.five_hour?.value.map { ($0, "14:00") }
            widget.seven = account.seven_day?.value.map { ($0, "FRI 14:00") }
            canvas.addSubview(widget)
        }
    case "--preview-menu":
        // Registration defaults are volatile: previewing never changes the
        // user's selected accounts or their saved menu preferences.
        let defaults = UserDefaults(suiteName: "ClaudeUsage.preview." + UUID().uuidString)!
        defaults.register(defaults: ["primaryAccount": "pho", "secondaryAccount": "codex-pro"])
        preferences = Preferences(defaults)
        let delegate = AppDelegate()
        delegate.accounts = signedOut ? [] : samples
        let menu = delegate.buildMenu()
        let heights = menu.items.map { $0.view?.frame.height ?? ($0.isSeparatorItem ? 10 : 24) }
        let height = heights.reduce(16, +)
        canvas = PreviewCanvas(frame: NSRect(x: 0, y: 0, width: 336, height: height))
        var y = height - 8
        for (index, item) in menu.items.enumerated() {
            y -= heights[index]
            if let view = item.view {
                item.view = nil
                view.frame.origin = NSPoint(x: 8, y: y)
                canvas.addSubview(view)
            } else if item.isSeparatorItem {
                let line = NSBox(frame: NSRect(x: 22, y: y + 4, width: 292, height: 1))
                line.boxType = .separator; canvas.addSubview(line)
            } else {
                let text = (item.state == .on ? "✓ " : "") + item.title + (item.submenu == nil ? "" : "  ▸")
                let label = NSTextField(labelWithString: text)
                label.font = NSFont.menuFont(ofSize: 13)
                label.textColor = item.isEnabled ? .labelColor : .secondaryLabelColor
                label.frame = NSRect(x: 22, y: y + 3, width: 292, height: 20)
                canvas.addSubview(label)
            }
        }
    default: return 2
    }
    canvas.appearance = appearance
    return writePreview(canvas, path: path)
}

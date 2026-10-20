import Cocoa
import UsageKit

@MainActor
func providerAccent(_ provider: Provider) -> NSColor {
    provider == .codex ? NSColor(red: 0.27, green: 0.31, blue: 0.38, alpha: 1) : clawdSalmon
}

@MainActor
func accountAvatar(_ account: UsageAccount?, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let color = account.map { providerAccent($0.provider) } ?? .tertiaryLabelColor
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    if account?.isCodex == true {
        let text = NSAttributedString(string: "›_", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size / 2, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        text.draw(at: NSPoint(x: (size - text.size().width) / 2, y: (size - text.size().height) / 2))
    } else {
        drawClawdGlyph(in: NSRect(x: size * 0.1875, y: size * 0.28125,
                                 width: size * 0.625, height: size * 0.4375), color: .white, eyeColor: color)
    }
    image.unlockFocus()
    image.isTemplate = false
    return image
}

@MainActor
private func menuLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.setAccessibilityElement(false)
    return label
}

@MainActor
final class AccountHeaderView: NSView {
    private let avatar: NSImage
    private let plan: String?
    private let status: String?
    private let statusColor: NSColor
    private let statusSymbol: String

    init(account: UsageAccount?, now: Date = Date()) {
        avatar = accountAvatar(account, size: 32)
        plan = MenuFormatting.planTitle(account?.plan)
        switch account?.state {
        case .stale:
            status = MenuFormatting.updated(since: account.flatMap(MenuFormatting.timestamp), now: now)
            statusColor = .systemOrange
            statusSymbol = "exclamationmark.triangle.fill"
        case .tokenRejected:
            status = String(localized: "Sign-in expired · renew in Settings")
            statusColor = .systemRed
            statusSymbol = "xmark.octagon.fill"
        case .error:
            status = String(localized: "Couldn't load usage")
            statusColor = .systemOrange
            statusSymbol = "exclamationmark.triangle.fill"
        default:
            status = nil
            statusColor = .secondaryLabelColor
            statusSymbol = ""
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: status == nil ? 44 : 69))
        // Preserve the existing 10pt gap above a 15pt status line.
        let extra: CGFloat = status == nil ? 0 : 25
        let name = account?.label ?? String(localized: "No accounts")
        let detail = account == nil ? String(localized: "Sign in to Claude Code to see your usage") : account?.email ?? ""
        let nameLabel = menuLabel(name, size: 13, weight: .semibold)
        let tagWidth = plan.map { ceil(Self.tagText($0).size().width) + 14 } ?? 0
        nameLabel.frame = NSRect(x: 56, y: 20 + extra, width: 230 - (plan == nil ? 0 : tagWidth + 8), height: 17)
        addSubview(nameLabel)
        let email = menuLabel(detail, size: 11, color: .secondaryLabelColor)
        email.lineBreakMode = .byTruncatingMiddle
        email.frame = NSRect(x: 56, y: 4 + extra, width: 230, height: 15)
        addSubview(email)
        if let status {
            let label = menuLabel(status, size: 11, color: statusColor)
            label.frame = NSRect(x: 30, y: 4, width: 256, height: 15)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let identity = [account?.providerName, plan].compactMap { $0 }.joined(separator: " ")
        setAccessibilityLabel([name, identity, detail, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }

    private static func tagText(_ plan: String) -> NSAttributedString {
        NSAttributedString(string: plan, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let extra: CGFloat = status == nil ? 0 : 25
        avatar.draw(in: NSRect(x: 14, y: 2 + extra, width: 32, height: 32))
        if let plan {
            let text = Self.tagText(plan)
            let width = ceil(text.size().width) + 14
            let rect = NSRect(x: 286 - width, y: 19.5 + extra, width: width, height: 18)
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            text.draw(at: NSPoint(x: rect.minX + 7, y: rect.midY - text.size().height / 2))
        }
        if status != nil, let symbol = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [statusColor]))
            symbol.withSymbolConfiguration(config)?.draw(in: NSRect(x: 14, y: 6, width: 12, height: 12))
        }
    }
}

@MainActor
final class UsageLimitRowView: NSView {
    private let limit: LimitInfo
    private let bottomPadding: CGFloat

    init(limit: LimitInfo, now: Date, first: Bool, last: Bool) {
        self.limit = limit
        bottomPadding = last ? 10 : 12
        // Header text ends 4pt above its edge; another 4pt makes the first gap 8pt.
        // Row content is title 16, gap 7, bar 5, gap 5, caption 15 = 48pt.
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 48 + (first ? 4 : 0) + bottomPadding))
        let name = MenuFormatting.limitName(limit)
        let percent = limit.value.map { String(localized: "\(Int($0.rounded()))%") } ?? String(localized: "–")
        let right = menuLabel(percent, size: 13, weight: .semibold,
                              color: (limit.value ?? 0) >= 90 ? .systemRed : .labelColor)
        right.sizeToFit()
        right.frame = NSRect(x: 286 - right.frame.width, y: 32 + bottomPadding, width: right.frame.width, height: 16)
        addSubview(right)
        let left = menuLabel(name, size: 13)
        left.frame = NSRect(x: 14, y: 32 + bottomPadding, width: right.frame.minX - 22, height: 16)
        addSubview(left)
        let caption = MenuFormatting.resetCaption(value: limit.value, reset: limit.resetsAt.flatMap(parseISO), now: now)
        let text = NSMutableAttributedString(string: caption, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let suffix = limit.status == "rejected" ? String(localized: " · Limit reached") : ""
        if !suffix.isEmpty {
            text.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.systemRed,
            ]))
        }
        let label = menuLabel("", size: 11)
        label.attributedStringValue = text
        label.frame = NSRect(x: 14, y: bottomPadding, width: 272, height: 15)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(name)
        setAccessibilityValue(percent)
        setAccessibilityHelp(caption + suffix)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 14, y: 20 + bottomPadding, width: 272, height: 5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        guard let value = limit.value, value > 0 else { return }
        let color = value >= 90 ? usageRed : (limit.kind == "session" ? usageOrange : usagePurple)
        color.setFill()
        let fill = NSRect(x: track.minX, y: track.minY, width: max(5, track.width * value / 100), height: 5)
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

@MainActor
enum UsageMenuViews {
    static func items(account: UsageAccount?, now: Date = Date()) -> [NSMenuItem] {
        var items = [item(with: AccountHeaderView(account: account, now: now))]
        guard let account, !account.failed else { return items }
        let limits: [LimitInfo]
        if let reported = account.limits, !reported.isEmpty { limits = reported }
        else {
            limits = [("session", account.fiveHour), ("weekly_all", account.sevenDay)].map { kind, limit in
                LimitInfo(resetsAt: limit?.resetsAt, kind: kind, percent: limit?.value, status: limit?.status)
            }
        }
        for (index, limit) in limits.enumerated() {
            items.append(item(with: UsageLimitRowView(limit: limit, now: now, first: index == 0, last: index == limits.count - 1)))
        }
        return items
    }

    private static func item(with view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }
}

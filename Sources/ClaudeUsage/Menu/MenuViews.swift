import Cocoa
import UsageKit

@MainActor
func providerAccent(_ provider: Provider) -> NSColor {
    provider == .codex ? NSColor(red: 0.27, green: 0.31, blue: 0.38, alpha: 1) : clawdSalmon
}

// The card shares the native item grid: text starts where item titles start
// (after the state column) and right-aligned content ends where the account
// rows' last number column ends, measured on macOS 27 without key equivalents.
enum MenuMetrics {
    static let leading: CGFloat = 30
    static let trailing: CGFloat = 24
}

@MainActor
func accountAvatar(_ account: UsageAccount?, size: CGFloat) -> NSImage {
    // Draw lazily: a lockFocus bitmap would freeze dynamic colors in whatever
    // appearance is current when the menu is built (the menu bar's, which is
    // dark over a dark wallpaper while the menu itself is light).
    let color = account.map { providerAccent($0.provider) } ?? .tertiaryLabelColor
    let isCodex = account?.isCodex == true
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    if isCodex {
        let text = NSAttributedString(string: "›_", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size / 2, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        text.draw(at: NSPoint(x: (size - text.size().width) / 2, y: (size - text.size().height) / 2))
    } else {
        drawClawdGlyph(in: NSRect(x: size * 0.1875, y: size * 0.28125,
                                 width: size * 0.625, height: size * 0.4375), color: .white, eyeColor: color)
    }
        return true
    }
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
    private let signedOut: Bool

    init(account: UsageAccount?, now: Date = Date()) {
        signedOut = account == nil
        avatar = accountAvatar(account, size: account == nil ? 32 : 28)
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
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: signedOut ? 44 : (status == nil ? 46 : 71)))
        autoresizingMask = [.width]
        // Preserve the existing 10pt gap above a 15pt status line.
        let extra: CGFloat = status == nil ? 0 : 25
        let name = account?.label ?? String(localized: "No accounts")
        let detail = account == nil ? String(localized: "Sign in to Claude Code to see your usage") : account?.email ?? ""
        let nameLabel = menuLabel(name, size: 13, weight: .semibold)
        let tagWidth = plan.map { ceil(Self.tagText($0).size().width) + 14 } ?? 0
        let textX: CGFloat = MenuMetrics.leading + (signedOut ? 42 : 38)
        let textY: CGFloat = signedOut || status != nil ? 4 : 8
        nameLabel.frame = NSRect(x: textX, y: textY + 16 + extra,
                                width: 300 - MenuMetrics.trailing - textX - (plan == nil ? 0 : tagWidth + 8), height: 17)
        nameLabel.autoresizingMask = [.width]
        addSubview(nameLabel)
        let email = menuLabel(detail, size: 11, color: .secondaryLabelColor)
        email.lineBreakMode = .byTruncatingMiddle
        email.frame = NSRect(x: textX, y: textY + extra, width: 300 - MenuMetrics.trailing - textX, height: 15)
        email.autoresizingMask = [.width]
        addSubview(email)
        if let status {
            let label = menuLabel(status, size: 11, color: statusColor)
            label.frame = NSRect(x: MenuMetrics.leading + 16, y: 4,
                                 width: 300 - MenuMetrics.trailing - MenuMetrics.leading - 16, height: 15)
            label.autoresizingMask = [.width]
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
        avatar.draw(in: NSRect(x: MenuMetrics.leading, y: (signedOut ? 2 : (status == nil ? 9 : 5)) + extra,
                              width: signedOut ? 32 : 28, height: signedOut ? 32 : 28))
        if let plan {
            let text = Self.tagText(plan)
            let width = ceil(text.size().width) + 14
            let rect = NSRect(x: bounds.width - MenuMetrics.trailing - width, y: (status == nil ? 23.5 : 19.5) + extra,
                              width: width, height: 18)
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            text.draw(at: NSPoint(x: rect.minX + 7, y: rect.midY - text.size().height / 2))
        }
        if status != nil, let symbol = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [statusColor]))
            symbol.withSymbolConfiguration(config)?.draw(in: NSRect(x: MenuMetrics.leading, y: 6, width: 12, height: 12))
        }
    }
}

@MainActor
final class UsageLimitRowView: NSView {
    private let limit: LimitInfo
    private let bottomPadding: CGFloat
    private let nameText: NSAttributedString
    private let valueText: NSAttributedString

    init(limit: LimitInfo, now: Date, first: Bool, last: Bool) {
        self.limit = limit
        bottomPadding = last ? 8 : 10
        let name = MenuFormatting.limitName(limit)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        nameText = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        let percent = limit.value.map { String(localized: "\(Int($0.rounded()))%") } ?? String(localized: "–")
        let reset = limit.resetsAt.flatMap(parseISO)
        let shortReset = MenuFormatting.shortResetText(value: limit.value, reset: reset, now: now)
        let text = NSMutableAttributedString(string: shortReset, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let suffix = limit.value != nil && limit.status == "rejected" ? String(localized: " · limit") : ""
        if !suffix.isEmpty {
            text.append(NSAttributedString(string: suffix, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: usageRed,
            ]))
        }
        if text.length > 0 {
            if !shortReset.isEmpty,
               let symbol = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = NSRect(x: 0, y: 0, width: 9, height: 9)
                let prefix = NSMutableAttributedString(attachment: attachment)
                prefix.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
                text.insert(prefix, at: 0)
            }
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            text.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 6 - spaceWidth]))
        }
        text.append(NSAttributedString(string: percent, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: (limit.value ?? 0) >= 90 || limit.status == "rejected" ? usageRed : NSColor.labelColor,
        ]))
        valueText = text
        // Text 16, gap 6, bar 4; 6 after the header, 10 between rows, 8 at the end.
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 26 + (first ? 6 : 0) + bottomPadding))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(name)
        setAccessibilityValue(limit.value.map { String(localized: "\(Int($0.rounded())) percent") }
                              ?? String(localized: "Not reported for this plan"))
        let help = MenuFormatting.resetHelp(value: limit.value, reset: reset, now: now)
        setAccessibilityHelp(help + (limit.status == "rejected" ? String(localized: " · Limit reached") : ""))
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rightX = bounds.width - MenuMetrics.trailing - valueText.size().width
        valueText.draw(at: NSPoint(x: rightX, y: bottomPadding + 10))
        nameText.draw(in: NSRect(x: MenuMetrics.leading, y: bottomPadding + 10,
                                 width: max(0, rightX - MenuMetrics.leading - 8), height: 16))
        let track = NSRect(x: MenuMetrics.leading, y: bottomPadding,
                           width: bounds.width - MenuMetrics.leading - MenuMetrics.trailing, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        guard let value = limit.value, value > 0 else { return }
        let color = value >= 90 ? usageRed : (limit.kind == "session" ? usageOrange : usagePurple)
        color.setFill()
        let fill = NSRect(x: track.minX, y: track.minY, width: max(5, track.width * value / 100), height: 4)
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
}

/// Attributed titles keep the account list in AppKit's native menu tracking.
@MainActor
enum AccountMenuTitle {
    static let titleInset: CGFloat = 22
    // Allow a 22pt native state/title gutter so the last column ends at x=286.
    // These are title-relative stops; verify the system gutter in native QA.
    static let sessionTab: CGFloat = 210
    static let weeklyTab: CGFloat = 264
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    static func make(_ account: UsageAccount) -> NSAttributedString {
        let failed = MenuFormatting.failedRowText(account.state)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = (failed == nil ? [sessionTab, weeklyTab] : [weeklyTab]).map {
            NSTextTab(textAlignment: .right, location: $0)
        }
        paragraph.defaultTabInterval = 0
        paragraph.lineBreakMode = .byClipping
        paragraph.baseWritingDirection = .leftToRight
        let text = NSMutableAttributedString(attributedString: attachment(providerGlyph(account.provider), y: -2))
        // Reserve room for a three-digit meter plus separation before the first tab.
        let labelWidth = sessionTab - 48 - 16 - 8
        text.append(NSAttributedString(string: " " + fittedLabel(account.label, width: labelWidth), attributes: [
            .font: font, .foregroundColor: account.state == .stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        text.append(NSAttributedString(string: "\t"))
        if let failed {
            text.append(NSAttributedString(string: failed, attributes: [
                .font: numberFont, .foregroundColor: NSColor.systemOrange,
            ]))
        } else {
            text.append(column(account.fiveHour?.value, color: usageOrange))
            text.append(NSAttributedString(string: "\t"))
            text.append(column(account.sevenDay?.value, color: usagePurple))
        }
        let range = NSRange(location: 0, length: text.length)
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return text
    }

    static func alternate(_ title: String) -> NSAttributedString {
        NSAttributedString(string: fittedLabel(title, width: weeklyTab), attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
    }

    static func fittedLabel(_ label: String, width: CGFloat) -> String {
        // Embedded newlines/tabs must not create a second line or a third column.
        let singleLine = label.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        func measured(_ value: String) -> CGFloat {
            (value as NSString).size(withAttributes: [.font: font]).width
        }
        guard measured(singleLine) > width else { return singleLine }
        var prefix = singleLine
        while !prefix.isEmpty, measured(prefix + "…") > width { prefix.removeLast() }
        return prefix + "…"
    }

    static func attachment(_ image: NSImage, y: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: NSPoint(x: 0, y: y), size: image.size)
        return NSAttributedString(attachment: attachment)
    }

    static func providerGlyph(_ provider: Provider?) -> NSImage {
        // Drawn at display time so labelColor follows the menu, not the menu bar.
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
        if provider == .claude {
            drawClawdGlyph(in: NSRect(x: 0, y: 0, width: 12, height: 12), color: .labelColor)
        } else if provider == .codex {
            let text = NSAttributedString(string: "›_", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ])
            text.draw(at: NSPoint(x: (12 - text.size().width) / 2, y: (12 - text.size().height) / 2))
        } else {
            NSColor.labelColor.setStroke()
            let card = NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 10, height: 8), xRadius: 2, yRadius: 2)
            card.lineWidth = 1
            card.stroke()
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: 1, y: 7))
            stripe.line(to: NSPoint(x: 11, y: 7))
            stripe.stroke()
        }
            return true
        }
    }

    private static func column(_ value: Double?, color: NSColor) -> NSAttributedString {
        let meter = NSImage(size: NSSize(width: 14, height: 4), flipped: false) { _ in
        let track = NSRect(x: 0, y: 0, width: 14, height: 4)
        // A touch stronger than quaternaryLabelColor so the track reads on the menu material.
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        if let value, value > 0 {
            (value >= 90 ? usageRed : color).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(3, 14 * value / 100), height: 4),
                         xRadius: 2, yRadius: 2).fill()
        }
            return true
        }
        let text = NSMutableAttributedString(attributedString: attachment(meter, y: 3))
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: numberFont]).width
        text.append(NSAttributedString(string: " ", attributes: [.font: numberFont, .kern: 4 - spaceWidth]))
        text.append(NSAttributedString(string: value.map { String(Int($0.rounded())) } ?? "–", attributes: [
            .font: numberFont, .foregroundColor: (value ?? 0) >= 90 ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]))
        return text
    }
}

/// Native items preserve AppKit's highlight, keyboard and click behavior.
@MainActor
enum CreditMenuTitle {
    static func make(_ provider: CreditProvider, row: CreditRowPresentation) -> NSAttributedString {
        let tint: NSColor = row.warning ? .systemOrange : (row.stale ? .secondaryLabelColor : .labelColor)
        let font = NSFont.systemFont(ofSize: 13)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let amountWidth = (row.amount as NSString).size(withAttributes: [.font: numberFont]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: AccountMenuTitle.weeklyTab)]
        paragraph.defaultTabInterval = 0
        paragraph.baseWritingDirection = .leftToRight
        paragraph.lineBreakMode = .byClipping
        let text = NSMutableAttributedString(attributedString: AccountMenuTitle.attachment(
            AccountMenuTitle.providerGlyph(provider.glyphProvider), y: -2))
        let label = AccountMenuTitle.fittedLabel(provider.label, width: max(0, AccountMenuTitle.weeklyTab - amountWidth - 28))
        text.append(NSAttributedString(string: " " + label, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: "\t" + row.amount, attributes: [.font: numberFont, .foregroundColor: tint]))
        if row.showsMeter {
            text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
            // Both track and fill resolve colors while drawing in the menu's appearance.
            let meter = NSImage(size: NSSize(width: 40, height: 4), flipped: false) { _ in
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 40, height: 4), xRadius: 2, yRadius: 2).fill()
                if row.fraction > 0 {
                    (row.warning ? NSColor.systemOrange : usagePurple).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(2, 40 * row.fraction), height: 4), xRadius: 2, yRadius: 2).fill()
                }
                return true
            }
            text.append(AccountMenuTitle.attachment(meter, y: 3))
            text.append(NSAttributedString(string: "  " + row.subtitle, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: row.warning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            ]))
        }
        if !row.annotation.isEmpty {
            text.append(NSAttributedString(string: "\n" + row.annotation, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
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

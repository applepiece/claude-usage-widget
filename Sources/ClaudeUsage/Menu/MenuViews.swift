import Cocoa
import UsageKit

@MainActor
private func menuLabel(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    return label
}

@MainActor
private func spacedText(_ text: String, font: NSFont, color: NSColor,
                        kern: CGFloat) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .kern: kern,
    ])
}

// The chip draws its own text instead of wrapping an NSTextField: a text field
// pins its glyphs to the top of its frame, which left MAX riding the upper edge
// of the pill. Drawing by hand is the only way to centre it on both axes.
@MainActor
private final class PlanPillView: NSView {
    private let text: NSAttributedString
    private let textWidth: CGFloat
    private let baselineY: CGFloat

    init(plan: String) {
        let kern: CGFloat = 0.6
        let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        text = spacedText(plan.uppercased(), font: font, color: .white, kern: kern)
        // kerning leaves a trailing gap after the last glyph, so drop it before
        // centring or the text lands slightly left
        textWidth = text.size().width - kern
        // An all-caps plan name has no descender, so centring the font's line
        // box would leave its empty descender space at the bottom and float the
        // text toward the top edge. Centre the cap height instead: draw(at:)
        // takes the bottom of the line box, which sits |descender| below the
        // baseline, hence the negative term.
        // A plan name is all caps, so its ink is exactly the cap height: centre
        // that, not the font's line box, or the box's empty descender space
        // floats the text toward the top edge. draw(at:) takes the bottom of the
        // line box, which sits this far below the baseline. Left unrounded so
        // the result is not quantised away from centre.
        let lineBottomToBaseline = text.size().height - font.ascender
        baselineY = (18 - font.capHeight) / 2 - lineBottomToBaseline
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: (ceil(textWidth) + 15).rounded(),
                                 height: 18))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        clawdSalmon.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: (bounds.width - textWidth) / 2, y: baselineY))
    }
}

@MainActor
private final class AccountRoleView: NSView {
    let role: String
    init(role: String) {
        self.role = role
        super.init(frame: NSRect(x: 0, y: 0, width: role == "PRIMARY" ? 53 : 68, height: 13))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        (role as NSString).draw(at: NSPoint(x: 5, y: 1),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .bold),
                                                 .foregroundColor: NSColor.secondaryLabelColor])
    }
}

@MainActor
final class AccountHeaderView: NSView {
    private let account: AccountInfo

    init(account: AccountInfo, role: String? = nil) {
        self.account = account
        let offset: CGFloat = role == nil ? 0 : 14
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 58 + offset))

        let email = account.email ?? ""
        let fallbackName = email.split(separator: "@", maxSplits: 1)
            .first.map(String.init) ?? "Claude user"
        let knownName = account.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = account.loggedIn
            ? ((knownName?.isEmpty == false ? knownName : nil) ?? fallbackName)
            : "Not signed in"
        let provider = account.provider == .codex ? "Codex" : "Claude"
        let detail = account.loggedIn ? provider + " · " + email : "Sign in to see your usage"
        let nameLabel = menuLabel(name, size: 13.5, weight: .semibold,
                                  color: .labelColor)
        let emailLabel = menuLabel(detail, size: 11.5, weight: .regular,
                                   color: .secondaryLabelColor)
        addSubview(nameLabel)
        addSubview(emailLabel)

        if let role {
            let chip = AccountRoleView(role: role)
            chip.frame.origin = NSPoint(x: 58, y: 5)
            addSubview(chip)
        }
        var textMaxX: CGFloat = 306
        if account.loggedIn, let plan = account.plan, !plan.isEmpty {
            let pill = PlanPillView(plan: plan)
            // centre the chip on the name line rather than pinning it by its top
            pill.frame.origin = NSPoint(x: 306 - pill.frame.width,
                                        y: 29 + offset + (17 - pill.frame.height) / 2)
            addSubview(pill)
            textMaxX = pill.frame.minX - 8
        }
        nameLabel.frame = NSRect(x: 58, y: 29 + offset, width: textMaxX - 58, height: 17)
        emailLabel.frame = NSRect(x: 58, y: 13 + offset, width: textMaxX - 58, height: 15)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isCodex = account.provider == .codex
        let avatarColor = isCodex ? NSColor(red: 0.27, green: 0.31, blue: 0.38, alpha: 1)
            : (account.loggedIn ? clawdSalmon : NSColor.tertiaryLabelColor)
        avatarColor.setFill()
        let circle = NSRect(x: 14, y: bounds.height - 46, width: 34, height: 34)
        NSBezierPath(ovalIn: circle).fill()
        if isCodex {
            let glyph = "›_" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
                       withAttributes: attributes)
        } else {
            drawClawdGlyph(in: NSRect(x: 21, y: bounds.height - 36, width: 20, height: 14),
                           color: .white, eyeColor: avatarColor)
        }

        // inset hairline: identity above, usage below. Drawn in the view rather
        // than as a menu separator so the preview renderer shows it too. Signed
        // out there is no usage section under it, so it would dangle.
        guard account.loggedIn else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: 0, width: 292, height: 1).fill()
    }
}

@MainActor
final class UsageSectionView: NSView {
    init(freshness: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let left = menuLabel("", size: 10, weight: .semibold,
                             color: .tertiaryLabelColor)
        left.attributedStringValue = spacedText(
            "PLAN USAGE LIMITS", font: font, color: .tertiaryLabelColor, kern: 0.6)
        left.frame = NSRect(x: 14, y: 4, width: 170, height: 14)
        addSubview(left)

        let right = menuLabel("", size: 10, weight: .semibold,
                              color: .tertiaryLabelColor)
        right.attributedStringValue = spacedText(
            freshness, font: font, color: .tertiaryLabelColor, kern: 0.6)
        right.sizeToFit()
        right.frame = NSRect(x: 306 - right.frame.width, y: 4,
                             width: right.frame.width, height: 14)
        addSubview(right)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class UsageLimitRowView: NSView {
    private let limit: LimitInfo
    private let percent: Double?

    init(limit: LimitInfo, now: Date) {
        self.limit = limit
        self.percent = limit.value
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 58))

        let label = menuLabel(Self.label(for: limit), size: 12.5,
                              weight: .regular, color: .labelColor)
        let rightText = percent.map { "\(Int($0.rounded()))% used" } ?? "–"
        let right = menuLabel(rightText, size: 12, weight: .semibold,
                              color: (percent ?? 0) >= 90 ? usageRed : .labelColor)
        right.sizeToFit()
        right.frame = NSRect(x: 306 - right.frame.width, y: 36,
                             width: right.frame.width, height: 16)
        label.frame = NSRect(x: 14, y: 36,
                             width: max(0, right.frame.minX - 22), height: 17)
        addSubview(label)
        addSubview(right)
        let resetText = percent == nil ? "Window unavailable" : Self.resetText(limit.resetsAt, now: now)
        let reset = menuLabel(resetText + (limit.status == "rejected" ? " · rejected" : ""),
                              size: 10.5, weight: .regular, color: .secondaryLabelColor)
        reset.frame = NSRect(x: 14, y: 4, width: 292, height: 15)
        addSubview(reset)
    }

    required init?(coder: NSCoder) { nil }

    private static func label(for limit: LimitInfo) -> String {
        switch limit.kind ?? "" {
        case "session":
            return "5-hour limit"
        case "weekly_all":
            return "Weekly · all models"
        case "weekly_scoped":
            if let name = limit.scope?.model?.displayName, !name.isEmpty {
                return "Weekly · " + name
            }
            return "Weekly · scoped"
        case let kind where !kind.isEmpty:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return "Usage limit"
        }
    }

    private static func resetText(_ value: String?, now: Date) -> String {
        guard let value, let date = parseISO(value) else { return "Ready · no active window" }
        return "Resets at " + UsageFormatting.resetDate.string(from: date)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 14, y: 25, width: 292, height: 5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

        guard let percent else { return }
        let clamped = min(100, max(0, percent))
        guard clamped > 0 else { return }
        let width = min(track.width, max(6, track.width * CGFloat(clamped) / 100))
        let color: NSColor
        if percent >= 90 {
            color = usageRed
        } else if limit.group == "session" {
            color = usageOrange
        } else {
            color = usagePurple
        }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                        width: width, height: track.height),
                     xRadius: 3, yRadius: 3).fill()
    }
}

@MainActor
enum UsageMenuViews {
    static func items(account: AccountInfo, usage: Usage?, role: String? = nil,
                      state: String = "ok", now: Date = Date()) -> [NSMenuItem] {
        var items = [item(with: AccountHeaderView(account: account, role: role))]
        guard account.loggedIn else { return items }

        let fetched = usage?.fetchedAt.map { Date(timeIntervalSince1970: $0) } ?? now
        items.append(item(with: UsageSectionView(
            freshness: state == "ok" ? freshnessText(since: fetched, now: now) : state.replacingOccurrences(of: "_", with: " ").uppercased())))
        for limit in limits(from: usage) {
            items.append(item(with: UsageLimitRowView(limit: limit, now: now)))
        }
        return items
    }

    private static func item(with view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private static func freshnessText(since date: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(date))
        if age < 60 { return "Updated just now" }
        if age < 60 * 60 { return "Updated \(Int(age / 60))m ago" }
        if age < 24 * 60 * 60 { return "Updated \(Int(age / (60 * 60)))h ago" }
        return "Updated \(Int(age / (24 * 60 * 60)))d ago"
    }

    private static func limits(from usage: Usage?) -> [LimitInfo] {
        if let limits = usage?.limits, !limits.isEmpty { return limits }
        var limits: [LimitInfo] = []
        limits.append(LimitInfo(resetsAt: usage?.fiveHour?.resetsAt,
                                kind: "session", group: "session", percent: usage?.fiveHour?.value,
                                status: usage?.fiveHour?.status))
        limits.append(LimitInfo(resetsAt: usage?.sevenDay?.resetsAt,
                                kind: "weekly_all", group: "weekly", percent: usage?.sevenDay?.value,
                                status: usage?.sevenDay?.status))
        return limits
    }
}


import Cocoa

let clawdSalmon = NSColor(red: 0.86, green: 0.47, blue: 0.34, alpha: 1)
let usageOrange = NSColor(red: 0.94, green: 0.50, blue: 0.19, alpha: 1)
let usagePurple = NSColor(red: 0.68, green: 0.35, blue: 0.78, alpha: 1)
let usageRed = NSColor(red: 0.94, green: 0.28, blue: 0.44, alpha: 1)

struct LimitModel: Decodable {
    let display_name: String?

    init(display_name: String? = nil) {
        self.display_name = display_name
    }
}

struct LimitScope: Decodable {
    let model: LimitModel?

    init(model: LimitModel? = nil) {
        self.model = model
    }
}

struct LimitInfo: Decodable {
    let utilization: Double?
    let resets_at: String?
    let kind: String?
    let group: String?
    let percent: Double?
    let scope: LimitScope?

    init(utilization: Double? = nil, resets_at: String? = nil,
         kind: String? = nil, group: String? = nil, percent: Double? = nil,
         scope: LimitScope? = nil) {
        self.utilization = utilization
        self.resets_at = resets_at
        self.kind = kind
        self.group = group
        self.percent = percent
        self.scope = scope
    }
}

struct Usage: Decodable {
    let five_hour: LimitInfo?
    let seven_day: LimitInfo?
    let limits: [LimitInfo]?
    let fetched_at: Double?
    let logged_in: Bool?

    init(five_hour: LimitInfo? = nil, seven_day: LimitInfo? = nil,
         limits: [LimitInfo]? = nil, fetched_at: Double? = nil,
         logged_in: Bool? = nil) {
        self.five_hour = five_hour
        self.seven_day = seven_day
        self.limits = limits
        self.fetched_at = fetched_at
        self.logged_in = logged_in
    }
}

struct AccountInfo: Decodable {
    let logged_in: Bool
    let email: String?
    let name: String?
    let plan: String?
    let org: String?
    // false when the profile lookup failed, so name/org are local fallbacks and
    // this answer is worth asking again sooner than the normal staleness gate
    let profile_ok: Bool?

    init(logged_in: Bool, email: String? = nil, name: String? = nil,
         plan: String? = nil, org: String? = nil, profile_ok: Bool? = nil) {
        self.logged_in = logged_in
        self.email = email
        self.name = name
        self.plan = plan
        self.org = org
        self.profile_ok = profile_ok
    }
}

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    let g = ISO8601DateFormatter()
    if let d = g.date(from: s) { return d }
    // strip long fractional seconds (API sends microseconds) and retry
    if let dot = s.firstIndex(of: ".") {
        let tail = s[dot...].drop(while: { $0 == "." || $0.isNumber })
        return g.date(from: String(s[..<dot]) + String(tail))
    }
    return nil
}

func fmtWhen(_ d: Date) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US")
    df.dateFormat = "HH:mm"
    let hm = df.string(from: d)
    let cal = Calendar.current
    if cal.isDateInToday(d) { return hm }
    if cal.isDateInTomorrow(d) { return "TMRW " + hm }
    df.dateFormat = "EEE"
    return df.string(from: d).uppercased() + " " + hm
}

// Register the bundled Press Start 2P pixel font (app bundle or dev tree).
func registerPixelFont() {
    let candidates = [
        Bundle.main.resourcePath.map { $0 + "/Fonts/PressStart2P-Regular.ttf" },
        ("~/claude-usage-widget/app/fonts/PressStart2P-Regular.ttf" as NSString).expandingTildeInPath,
    ].compactMap { $0 }
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
        return
    }
}

func pixelFont(_ size: CGFloat) -> NSFont {
    NSFont(name: "PressStart2P-Regular", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
}

// Shared geometry keeps the status glyph and account avatar in sync.
func drawClawdGlyph(in rect: NSRect, color: NSColor,
                    eyeColor: NSColor? = nil) {
    let scale = min(rect.width / 20, rect.height / 14)
    let x0 = rect.midX - 10 * scale
    let y0 = rect.midY - 7 * scale
    func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        NSRect(x: x0 + x * scale, y: y0 + y * scale,
               width: width * scale, height: height * scale).fill()
    }

    color.setFill()
    fill(4, 4, 12, 10)
    fill(1, 8, 3, 3); fill(16, 8, 3, 3)
    fill(4, 0, 2, 4); fill(7, 0, 2, 4)
    fill(11, 0, 2, 4); fill(14, 0, 2, 4)
    if let eyeColor {
        eyeColor.setFill()
    } else {
        NSGraphicsContext.current?.compositingOperation = .clear
    }
    fill(6, 10, 2, 2); fill(11, 10, 2, 2)
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}

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

private func spacedText(_ text: String, font: NSFont, color: NSColor,
                        kern: CGFloat) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .kern: kern,
    ])
}

private final class PlanPillLabel: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        clawdSalmon.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}

final class AccountHeaderView: NSView {
    private let account: AccountInfo

    init(account: AccountInfo) {
        self.account = account
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 58))

        let email = account.email ?? ""
        let fallbackName = email.split(separator: "@", maxSplits: 1)
            .first.map(String.init) ?? "Claude user"
        let knownName = account.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = account.logged_in
            ? ((knownName?.isEmpty == false ? knownName : nil) ?? fallbackName)
            : "Not signed in"
        let detail = account.logged_in ? email : "Sign in to see your usage"
        let nameLabel = menuLabel(name, size: 13.5, weight: .semibold,
                                  color: .labelColor)
        let emailLabel = menuLabel(detail, size: 11.5, weight: .regular,
                                   color: .secondaryLabelColor)
        addSubview(nameLabel)
        addSubview(emailLabel)

        var textMaxX: CGFloat = 306
        if account.logged_in, let plan = account.plan, !plan.isEmpty {
            let pill = PlanPillLabel(labelWithString: "")
            pill.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
            pill.textColor = .white
            pill.attributedStringValue = spacedText(
                plan.uppercased(), font: pill.font!, color: .white, kern: 0.4)
            pill.alignment = .center
            pill.sizeToFit()
            let pillWidth = ceil(pill.frame.width) + 10
            pill.frame = NSRect(x: 306 - pillWidth, y: 21,
                                width: pillWidth, height: 17)
            addSubview(pill)
            textMaxX = pill.frame.minX - 8
        }
        nameLabel.frame = NSRect(x: 58, y: 29, width: textMaxX - 58, height: 17)
        emailLabel.frame = NSRect(x: 58, y: 13, width: textMaxX - 58, height: 15)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let avatarColor = account.logged_in ? clawdSalmon : NSColor.tertiaryLabelColor
        avatarColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: 12, width: 34, height: 34)).fill()
        drawClawdGlyph(in: NSRect(x: 21, y: 22, width: 20, height: 14),
                       color: .white, eyeColor: avatarColor)

        // inset hairline: identity above, usage below. Drawn in the view rather
        // than as a menu separator so the preview renderer shows it too. Signed
        // out there is no usage section under it, so it would dangle.
        guard account.logged_in else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: 0, width: 292, height: 1).fill()
    }
}

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

final class UsageLimitRowView: NSView {
    private let limit: LimitInfo
    private let percent: Double

    init(limit: LimitInfo, now: Date) {
        self.limit = limit
        self.percent = limit.percent ?? limit.utilization ?? 0
        // 44 tall so the bar hugs its own label (5pt) and the next row starts
        // 16pt away: the pair has to read as one unit, not as evenly spaced lines
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 44))

        let label = menuLabel(Self.label(for: limit), size: 12.5,
                              weight: .regular, color: .labelColor)
        let pct = Int(percent.rounded())
        let reset = Self.resetText(limit.resets_at, now: now)
        let rightText = "\(pct)% · \(reset)"
        let right = menuLabel("", size: 12, weight: .regular,
                              color: .secondaryLabelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let status = NSMutableAttributedString(string: rightText, attributes: attributes)
        if percent >= 90 {
            status.addAttribute(.foregroundColor, value: usageRed,
                                range: NSRange(location: 0, length: "\(pct)%".utf16.count))
        }
        right.attributedStringValue = status
        right.sizeToFit()
        right.frame = NSRect(x: 306 - right.frame.width, y: 24,
                             width: right.frame.width, height: 16)
        label.frame = NSRect(x: 14, y: 24,
                             width: max(0, right.frame.minX - 22), height: 17)
        addSubview(label)
        addSubview(right)
    }

    required init?(coder: NSCoder) { nil }

    private static func label(for limit: LimitInfo) -> String {
        switch limit.kind ?? "" {
        case "session":
            return "5-hour limit"
        case "weekly_all":
            return "Weekly · all models"
        case "weekly_scoped":
            if let name = limit.scope?.model?.display_name, !name.isEmpty {
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
        guard let value, let date = parseISO(value) else { return "ready" }
        let remaining = max(0, date.timeIntervalSince(now))
        if remaining < 60 * 60 {
            return "resets \(max(1, Int(remaining / 60)))m"
        }
        if remaining < 24 * 60 * 60 {
            return "resets \(max(1, Int(remaining / (60 * 60))))h"
        }
        return "resets \(max(1, Int(remaining / (24 * 60 * 60))))d"
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 14, y: 13, width: 292, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

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

enum UsageMenuViews {
    static func items(account: AccountInfo, usage: Usage?, now: Date = Date()) -> [NSMenuItem] {
        var items = [item(with: AccountHeaderView(account: account))]
        guard account.logged_in else { return items }

        let fetched = usage?.fetched_at.map { Date(timeIntervalSince1970: $0) } ?? now
        items.append(item(with: UsageSectionView(
            freshness: freshnessText(since: fetched, now: now))))
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
        if let five = usage?.five_hour {
            limits.append(LimitInfo(
                resets_at: five.resets_at, kind: "session", group: "session",
                percent: five.percent ?? five.utilization))
        }
        if let seven = usage?.seven_day {
            limits.append(LimitInfo(
                resets_at: seven.resets_at, kind: "weekly_all", group: "weekly",
                percent: seven.percent ?? seven.utilization))
        }
        return limits
    }
}

final class WidgetView: NSView {
    var five: (pct: Double, when: String)?
    var seven: (pct: Double, when: String)?
    var offline = true
    var signedOut = false
    var t: CGFloat = 0            // animation clock (seconds)
    var danceUntil: CGFloat = -1  // celebrate until this clock value
    var nightOverride: Bool?      // preview hook

    // click Claw'd's legs to tuck the widget into the menu bar
    var onLegClick: (() -> Void)?
    // context menu is rebuilt on each open so checkmarks stay in sync
    var menuProvider: (() -> NSMenu)?
    private(set) var legHitRect: NSRect = .zero

    // manual drag (so a click on the legs is distinguishable from a move)
    private var dragOrigin: NSPoint = .zero
    private var mouseDownScreen: NSPoint = .zero
    private var dragged = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        mouseDownScreen = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownScreen.x
        let dy = now.y - mouseDownScreen.y
        if abs(dx) > 2 || abs(dy) > 2 { dragged = true }
        window?.setFrameOrigin(NSPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        if legHitRect.contains(p) { onLegClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    // The official blocky Claw'd figure as a monochrome menu-bar template
    // (auto-tints white on a dark bar, black on a light bar). Drawn on a 20×14
    // grid (y-up) with straight stub arms; the figure fills the whole canvas so
    // it reads large in the bar. The two eyes are punched-through holes.
    static func menuBarIcon() -> NSImage {
        let gw: CGFloat = 20, gh: CGFloat = 14
        let c: CGFloat = 17.0 / gh          // scale so the image is about 17pt tall
        let img = NSImage(size: NSSize(width: gw * c, height: gh * c), flipped: false) { _ in
            drawClawdGlyph(
                in: NSRect(x: 0, y: 0, width: gw * c, height: gh * c),
                color: .black)
            return true
        }
        img.isTemplate = true
        return img
    }

    // Pokemon-ish flat palette (fixed per row: orange = 5H, purple = WK)
    private let orangeFill = usageOrange
    private let purpleFill = usagePurple

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var severity: Int {  // 0 ok, 1 worried, 2 panic
        let p = max(five?.pct ?? 0, seven?.pct ?? 0)
        if p >= 90 { return 2 }
        if p >= 70 { return 1 }
        return 0
    }

    private var isNight: Bool {
        if let o = nightOverride { return o }
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 22 || h < 7
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBar(y: 42, data: five, fill: orangeFill)
        drawBar(y: 10, data: seven, fill: purpleFill)
        drawClawd()
    }

    // ============ compact flat Pokemon-style bars ============
    private func drawBar(y: CGFloat, data: (pct: Double, when: String)?, fill: NSColor) {
        let border = isDark ? NSColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1)
                            : NSColor(red: 0.15, green: 0.13, blue: 0.10, alpha: 1)
        let track = isDark ? NSColor(red: 0.23, green: 0.22, blue: 0.19, alpha: 1)
                           : NSColor(red: 0.94, green: 0.90, blue: 0.80, alpha: 1)
        let ink = isDark ? NSColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)
                         : NSColor(red: 0.15, green: 0.13, blue: 0.10, alpha: 1)

        let barX: CGFloat = 72
        let box = NSRect(x: barX, y: y, width: bounds.width - barX - 8, height: 22)
        let pct = min(100, max(0, data?.pct ?? 0))

        func notched(_ r: NSRect, _ notch: CGFloat) {
            NSRect(x: r.minX + notch, y: r.minY, width: r.width - notch * 2, height: r.height).fill()
            NSRect(x: r.minX, y: r.minY + notch, width: r.width, height: r.height - notch * 2).fill()
        }
        border.setFill()
        notched(box, 2)
        track.setFill()
        notched(box.insetBy(dx: 2, dy: 2), 2)

        if !offline, !signedOut, pct > 0 {
            let inner = box.insetBy(dx: 3, dy: 3)
            let w = max(4, (inner.width * CGFloat(pct) / 100).rounded())
            fill.setFill()
            NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height).fill()
        }

        let font = pixelFont(8)
        let when = signedOut ? "SIGN IN" : (offline ? "OFFLINE" : (data?.when ?? "-"))
        (when as NSString).draw(
            at: NSPoint(x: box.minX + 7, y: y + 7),
            withAttributes: [.font: font, .foregroundColor: ink])
        let ps = ((offline || signedOut) ? "-%" : "\(Int(pct.rounded()))%") as NSString
        let sz = ps.size(withAttributes: [.font: font])
        ps.draw(at: NSPoint(x: box.maxX - 7 - sz.width, y: y + 7),
                withAttributes: [.font: font, .foregroundColor: ink])
    }

    // ============ Claw'd — 3/4 angled view, hobby poses ============
    // Grid 20×20, u=3. Facing front-left: right columns are the darker side plane,
    // back legs shorter+darker for depth. Rows 0-1 = hat/prop headroom.
    private enum Pose { case idle, read, computer, music, camera, cook, sleep, dance }

    private var pose: Pose {
        if severity > 0 { return .idle }
        if t < danceUntil { return .dance }
        if isNight { return .sleep }
        let cycle: [Pose] = [.idle, .read, .computer, .music, .camera, .cook]
        return cycle[Int(t / 7) % cycle.count]
    }

    // palette (official salmon + side plane)
    private let base = clawdSalmon
    private let baseHi = NSColor(red: 0.92, green: 0.57, blue: 0.44, alpha: 1)
    private let baseLo = NSColor(red: 0.66, green: 0.32, blue: 0.22, alpha: 1)
    private let side = NSColor(red: 0.74, green: 0.38, blue: 0.27, alpha: 1)
    private let inkC = NSColor(red: 0.12, green: 0.09, blue: 0.07, alpha: 1)

    private func drawClawd() {
        let u: CGFloat = 3
        let mood = severity
        let p = pose
        let dancing = (p == .dance)
        let bobBase = dancing ? CGFloat(Int(t * 4) % 2) * 3 - 1 : (sin(t * (p == .sleep ? 1.0 : 2.0)) * 2).rounded()
        let jitter = mood == 2 ? (sin(t * 22) * 1).rounded() : 0
        let ox = 4 + jitter
        let oyTop = 70 + bobBase

        // clickable leg band (below the body) — click to tuck into the menu bar
        legHitRect = NSRect(x: ox, y: oyTop - 19 * u, width: 18 * u, height: 7 * u)

        func cell(_ gx: Int, _ gy: Int, _ w: Int = 1, _ h: Int = 1, _ c: NSColor) {
            c.setFill()
            NSRect(x: ox + CGFloat(gx) * u, y: oyTop - CGFloat(gy + h) * u,
                   width: CGFloat(w) * u, height: CGFloat(h) * u).fill()
        }
        func gp(_ gx: CGFloat, _ gy: CGFloat) -> NSPoint {
            NSPoint(x: ox + gx * u, y: oyTop - gy * u)
        }

        // floor shadow (fixed — sells the float)
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.16).setFill()
        NSRect(x: ox + 4 * u, y: 6, width: 12 * u, height: 2).fill()

        // legs — front pair full, back pair shorter + darker (depth)
        let liftA = (dancing ? Int(t * 4) : Int(sin(t * 3.0) > 0 ? 1 : 0)) % 2
        let liftB = 1 - liftA
        let kick = dancing ? 1 : 0
        for (gx, lift) in [(11, liftB), (14, liftA)] {   // back legs first
            cell(gx, 14, 2, 4 - lift - kick, side)
            cell(gx, 17 - lift - kick, 2, 1, baseLo)
        }
        for (gx, lift) in [(3, liftA), (7, liftB)] {     // front legs
            cell(gx, 14, 2, 5 - lift - kick, base)
            cell(gx, 18 - lift - kick, 2, 1, baseLo)
        }

        // body: front face + right side plane + top highlight
        cell(2, 2, 13, 12, base)
        cell(15, 2, 3, 12, side)
        cell(2, 2, 13, 1, baseHi)
        cell(15, 2, 3, 1, base)
        cell(2, 13, 16, 1, baseLo)

        // arms + pose props (held toward the facing side)
        switch p {
        case .idle:
            let wave = sin(t * 2.5) > 0.2 ? 2 : 0
            cell(0, 6 - wave, 2, 3, base)
            cell(0, 8 - wave, 2, 1, baseLo)
            cell(18, 6, 1, 2, side)
        case .dance:
            // both arms up, alternating; sparkles around
            let up = Int(t * 4) % 2
            cell(0, 3 + up, 2, 3, base)
            cell(18, 4 - up, 2, 3, side)
            let sp = NSColor(red: 1.0, green: 0.85, blue: 0.35, alpha: 1)
            if up == 0 { cell(1, 0, 1, 1, sp); cell(17, 2, 1, 1, sp) }
            else { cell(3, 1, 1, 1, sp); cell(19, 0, 1, 1, sp) }
        case .sleep:
            cell(0, 7, 2, 3, base)
            cell(18, 7, 1, 2, side)
            // rising Zzz (pixel font)
            let phase = Int(t) % 3
            let zc = isDark ? NSColor(white: 0.9, alpha: 1) : inkC
            if phase >= 0 { ("z" as NSString).draw(at: gp(15.5, 2.2), withAttributes: [.font: pixelFont(6), .foregroundColor: zc]) }
            if phase >= 1 { ("z" as NSString).draw(at: gp(17, 1.0), withAttributes: [.font: pixelFont(7), .foregroundColor: zc]) }
            if phase >= 2 { ("Z" as NSString).draw(at: gp(18.2, -0.4), withAttributes: [.font: pixelFont(8), .foregroundColor: zc]) }
        case .read:
            cell(4, 8, 8, 5, NSColor(red: 0.27, green: 0.62, blue: 0.33, alpha: 1))
            cell(5, 8, 2, 3, NSColor(red: 0.96, green: 0.95, blue: 0.89, alpha: 1))
            cell(9, 8, 2, 3, NSColor(red: 0.96, green: 0.95, blue: 0.89, alpha: 1))
            cell(7, 8, 2, 5, NSColor(red: 0.20, green: 0.48, blue: 0.26, alpha: 1))
            cell(2, 9, 2, 2, base)
            cell(12, 9, 2, 2, side)
        case .computer:
            cell(4, 7, 8, 5, NSColor(red: 0.24, green: 0.24, blue: 0.28, alpha: 1))
            cell(5, 8, 6, 3, NSColor(red: 0.55, green: 0.76, blue: 0.95, alpha: 1))
            let cur = Int(t * 2) % 4
            cell(5 + cur, 9, 1, 1, NSColor(red: 0.20, green: 0.35, blue: 0.55, alpha: 1))
            cell(3, 12, 10, 2, NSColor(red: 0.36, green: 0.36, blue: 0.40, alpha: 1))
            cell(2, 11, 2, 2, base)
            cell(12, 11, 2, 2, side)
        case .music:
            let blue = NSColor(red: 0.34, green: 0.45, blue: 0.76, alpha: 1)
            let blueDk = NSColor(red: 0.26, green: 0.35, blue: 0.60, alpha: 1)
            cell(4, 0, 10, 1, blue)
            cell(2, 1, 3, 1, blue)
            cell(13, 1, 3, 1, blueDk)
            cell(0, 2, 2, 5, blue)          // near pad (big)
            cell(16, 2, 2, 4, blueDk)       // far pad (smaller, darker)
            let hop = Int(t * 2) % 2
            let zc = inkC
            cell(16, 1 - min(1, hop), 1, 2, zc)
            cell(15, 3 - min(1, hop), 1, 1, zc)
            cell(18, 2 - (1 - hop), 1, 2, zc)
            cell(19, 4 - (1 - hop), 1, 1, zc)
            let g = hop == 0 ? 1 : 0
            cell(0, 8 - g, 2, 3, base)
            cell(18, 7 + g, 1, 2, side)
        case .camera:
            cell(4, 6, 8, 4, NSColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1))
            cell(5, 7, 2, 2, NSColor(red: 0.55, green: 0.72, blue: 0.90, alpha: 1))
            cell(11, 5, 2, 1, NSColor(red: 0.30, green: 0.28, blue: 0.26, alpha: 1))
            cell(2, 7, 2, 2, base)
            cell(12, 7, 2, 2, side)
            if t.truncatingRemainder(dividingBy: 3.5) < 0.3 {
                let fl = NSColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1)
                cell(1, 1, 1, 1, fl); cell(0, 2, 1, 1, fl); cell(2, 2, 1, 1, fl)
                cell(1, 3, 1, 1, fl); cell(1, 2, 1, 1, NSColor.white)
            }
        case .cook:
            let hatW = NSColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)
            cell(5, 0, 8, 2, hatW)
            cell(4, 1, 1, 1, hatW)
            cell(13, 1, 1, 1, NSColor(red: 0.84, green: 0.84, blue: 0.88, alpha: 1))
            cell(5, 1, 8, 1, NSColor(red: 0.84, green: 0.84, blue: 0.88, alpha: 1))
            cell(0, 9, 5, 2, NSColor(red: 0.28, green: 0.28, blue: 0.31, alpha: 1))
            cell(5, 9, 2, 1, NSColor(red: 0.48, green: 0.33, blue: 0.20, alpha: 1))
            cell(6, 8, 2, 2, base)
            let s = Int(t * 3) % 3
            let steam = NSColor(white: isDark ? 0.85 : 0.55, alpha: 0.8)
            cell(1, 7 - s, 1, 1, steam)
            cell(3, 6 - ((s + 1) % 3), 1, 1, steam)
        }

        // face — eyes sit on the front-left plane (3/4 view)
        switch mood {
        case 0:
            let blink = t.truncatingRemainder(dividingBy: 3.4) > 3.2
            let closed = (p == .music || p == .sleep || p == .dance)
            let down = (p == .read) ? 1 : 0
            if blink || closed {
                cell(5, 5 + down, 2, 1, inkC)
                cell(10, 5 + down, 2, 1, inkC)
            } else {
                cell(5, 4 + down, 2, 2, inkC)
                cell(10, 4 + down, 2, 2, inkC)
            }
        case 1:
            cell(5, 5, 2, 1, inkC)
            cell(10, 5, 2, 1, inkC)
        default:
            cell(4, 3, 2, 1, inkC); cell(5, 4, 2, 1, inkC); cell(4, 5, 2, 1, inkC)
            cell(11, 3, 2, 1, inkC); cell(10, 4, 2, 1, inkC); cell(11, 5, 2, 1, inkC)
            let drip = Int(t * 5) % 5
            cell(16, drip, 1, 2, NSColor(red: 0.35, green: 0.66, blue: 0.94, alpha: 1))
        }
    }
}

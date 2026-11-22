import Cocoa
import UsageKit

@MainActor
final class WidgetView: NSView {
    var accountTag = ""
    var showsMascot = true
    var bars: [(metric: UsageMetric, data: (pct: Double, when: String)?)] =
        UsageMetric.defaultSlots.map { ($0, nil) }
    private var severity = 0
    var offline = true
    var signedOut = false
    var reduceMotion = false
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

    func configureBars(account: UsageAccount?, slots: [UsageMetric]) {
        severity = UsageBarLayout.moodSeverity(for: account)
        bars = slots.map { metric in
            let data = account.flatMap { metric.value(for: $0) }
            return (metric, data.map { ($0.percent, $0.resetsAt.map { fmtWhen($0) } ?? String(localized: "READY")) })
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var isNight: Bool {
        if let o = nightOverride { return o }
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 22 || h < 7
    }

    override func draw(_ dirtyRect: NSRect) {
        let origins = UsageBarLayout.widgetBarOrigins(count: bars.count)
        for (index, bar) in bars.enumerated() {
            drawBar(y: CGFloat(origins[index]), data: bar.data, metric: bar.metric)
        }
        if showsMascot { drawClawd() }
    }

    // ============ compact flat Pokemon-style bars ============
    private func drawBar(y: CGFloat, data: (pct: Double, when: String)?, metric: UsageMetric) {
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

        if !offline, !signedOut, data != nil, pct > 0 {
            let inner = box.insetBy(dx: 3, dy: 3)
            let w = max(4, (inner.width * CGFloat(pct) / 100).rounded())
            metric.barColor.setFill()
            NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height).fill()
        }

        let font = pixelFont(8)
        let status = signedOut ? String(localized: "SIGN IN") : (offline ? String(localized: "OFFLINE") : (data?.when ?? "–"))
        // the account tag rides inside the bar (only set when two accounts are stacked),
        // so the widget keeps its original size and nothing floats over the wallpaper
        let ps = ((offline || signedOut || data == nil) ? "–" : "\(Int(pct.rounded()))%") as NSString
        let sz = ps.size(withAttributes: [.font: font])
        let labelWidth = box.width - 14 - sz.width - 4
        let when = metric.widgetLabel(reset: status, accountTag: accountTag, availableWidth: Double(labelWidth)) {
            Double(($0 as NSString).size(withAttributes: [.font: font]).width)
        }
        (when as NSString).draw(at: NSPoint(x: box.minX + 7, y: y + 7),
                               withAttributes: [.font: font, .foregroundColor: ink])
        ps.draw(at: NSPoint(x: box.maxX - 7 - sz.width, y: y + 7),
                withAttributes: [.font: font, .foregroundColor: ink])
    }

    // ============ Claw'd: 3/4 angled view, hobby poses ============
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
        // Keep the seven-second pose clock running, but freeze every movement
        // within a pose, including props, blinking, warning jitter and dancing.
        let t: CGFloat = reduceMotion ? 0 : self.t
        let dancing = (p == .dance)
        let bobBase = reduceMotion ? 0 : dancing ? CGFloat(Int(t * 4) % 2) * 3 - 1 : (sin(t * (p == .sleep ? 1.0 : 2.0)) * 2).rounded()
        let jitter = !reduceMotion && mood == 2 ? (sin(t * 22) * 1).rounded() : 0
        let ox = 4 + jitter
        let mascotOffset = bounds.height - 74
        let oyTop = 70 + mascotOffset + bobBase

        // clickable leg band (below the body): click to tuck into the menu bar
        legHitRect = NSRect(x: ox, y: oyTop - 19 * u, width: 18 * u, height: 7 * u)

        func cell(_ gx: Int, _ gy: Int, _ w: Int = 1, _ h: Int = 1, _ c: NSColor) {
            c.setFill()
            NSRect(x: ox + CGFloat(gx) * u, y: oyTop - CGFloat(gy + h) * u,
                   width: CGFloat(w) * u, height: CGFloat(h) * u).fill()
        }
        func gp(_ gx: CGFloat, _ gy: CGFloat) -> NSPoint {
            NSPoint(x: ox + gx * u, y: oyTop - gy * u)
        }

        // floor shadow (fixed: sells the float)
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.16).setFill()
        NSRect(x: ox + 4 * u, y: max(0, 6 + mascotOffset), width: 12 * u, height: 2).fill()

        // legs: front pair full, back pair shorter + darker (depth)
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

        // face: eyes sit on the front-left plane (3/4 view)
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

import Cocoa

struct LimitInfo: Decodable {
    let utilization: Double?
    let resets_at: String?
}
struct Usage: Decodable {
    let five_hour: LimitInfo?
    let seven_day: LimitInfo?
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

final class WidgetView: NSView {
    var five: (pct: Double, when: String)?
    var seven: (pct: Double, when: String)?
    var offline = true
    var t: CGFloat = 0            // animation clock (seconds)
    var danceUntil: CGFloat = -1  // celebrate until this clock value
    var nightOverride: Bool?      // preview hook

    // Pokemon-ish flat palette (fixed per row: orange = 5H, purple = WK)
    private let orangeFill = NSColor(red: 0.94, green: 0.50, blue: 0.19, alpha: 1)  // #F08030
    private let purpleFill = NSColor(red: 0.68, green: 0.35, blue: 0.78, alpha: 1)  // #AE5AC8

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
        drawBar(y: 54, data: five, fill: orangeFill)
        drawBar(y: 22, data: seven, fill: purpleFill)
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

        let barX: CGFloat = 96
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

        if !offline, pct > 0 {
            let inner = box.insetBy(dx: 3, dy: 3)
            let w = max(4, (inner.width * CGFloat(pct) / 100).rounded())
            fill.setFill()
            NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height).fill()
        }

        let font = pixelFont(8)
        let when = offline ? "OFFLINE" : (data?.when ?? "-")
        (when as NSString).draw(
            at: NSPoint(x: box.minX + 7, y: y + 7),
            withAttributes: [.font: font, .foregroundColor: ink])
        let ps = (offline ? "-%" : "\(Int(pct.rounded()))%") as NSString
        let sz = ps.size(withAttributes: [.font: font])
        ps.draw(at: NSPoint(x: box.maxX - 7 - sz.width, y: y + 7),
                withAttributes: [.font: font, .foregroundColor: ink])
    }

    // ============ Claw'd — Among Us style: bean body, big visor, backpack,
    // dark outline around every shape (that's what makes it readable) ============
    private enum Pose { case idle, read, computer, music, camera, cook, sleep, dance }

    private var pose: Pose {
        if severity > 0 { return .idle }
        if t < danceUntil { return .dance }
        if isNight { return .sleep }
        let cycle: [Pose] = [.idle, .read, .computer, .music, .camera, .cook]
        return cycle[Int(t / 7) % cycle.count]
    }

    // palette
    private let base = NSColor(red: 0.86, green: 0.47, blue: 0.34, alpha: 1)   // salmon
    private let baseHi = NSColor(red: 0.93, green: 0.58, blue: 0.45, alpha: 1)
    private let baseLo = NSColor(red: 0.69, green: 0.34, blue: 0.23, alpha: 1)
    private let sideC = NSColor(red: 0.74, green: 0.38, blue: 0.27, alpha: 1)
    private let lineC = NSColor(red: 0.27, green: 0.12, blue: 0.08, alpha: 1)  // outline
    private let inkC = NSColor(red: 0.10, green: 0.07, blue: 0.05, alpha: 1)
    private let glass = NSColor(red: 0.72, green: 0.88, blue: 0.91, alpha: 1)
    private let glassHi = NSColor(red: 0.92, green: 0.98, blue: 0.99, alpha: 1)
    private let glassLo = NSColor(red: 0.52, green: 0.70, blue: 0.76, alpha: 1)

    // draw a group of blocks with an auto-computed dark outline around the union
    private func outlined(_ parts: [(gx: Int, gy: Int, w: Int, h: Int, c: NSColor)],
                          u: CGFloat, ox: CGFloat, oyTop: CGFloat) {
        var cells = [Int: [Int: NSColor]]()
        for p in parts {
            for y in p.gy..<(p.gy + p.h) {
                for x in p.gx..<(p.gx + p.w) { cells[y, default: [:]][x] = p.c }
            }
        }
        func rect(_ x: Int, _ y: Int) -> NSRect {
            NSRect(x: ox + CGFloat(x) * u, y: oyTop - CGFloat(y + 1) * u, width: u, height: u)
        }
        lineC.setFill()
        for (y, row) in cells {
            for (x, _) in row {
                for dy in -1...1 {
                    for dx in -1...1 where cells[y + dy]?[x + dx] == nil {
                        rect(x + dx, y + dy).fill()
                    }
                }
            }
        }
        for (y, row) in cells {
            for (x, c) in row { c.setFill(); rect(x, y).fill() }
        }
    }

    private func drawClawd() {
        let u: CGFloat = 4
        let mood = severity
        let p = pose
        let dancing = (p == .dance)
        let bob = dancing ? CGFloat(Int(t * 4) % 2) * 3 - 1
                          : (sin(t * (p == .sleep ? 1.0 : 2.0)) * 2).rounded()
        let jitter = mood == 2 ? (sin(t * 22) * 1).rounded() : 0
        let ox = 5 + jitter
        let oyTop = 90 + bob

        func cell(_ gx: Int, _ gy: Int, _ w: Int = 1, _ h: Int = 1, _ c: NSColor) {
            c.setFill()
            NSRect(x: ox + CGFloat(gx) * u, y: oyTop - CGFloat(gy + h) * u,
                   width: CGFloat(w) * u, height: CGFloat(h) * u).fill()
        }
        func gp(_ gx: CGFloat, _ gy: CGFloat) -> NSPoint {
            NSPoint(x: ox + gx * u, y: oyTop - gy * u)
        }
        func group(_ parts: [(gx: Int, gy: Int, w: Int, h: Int, c: NSColor)]) {
            outlined(parts, u: u, ox: ox, oyTop: oyTop)
        }

        // floor shadow (fixed — sells the float)
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.16).setFill()
        NSRect(x: ox + 4 * u, y: 4, width: 13 * u, height: 2).fill()

        // ---- crewmate silhouette: bean body + backpack + legs (one outline) ----
        let liftA = (dancing ? Int(t * 4) : (sin(t * 3.0) > 0 ? 1 : 0)) % 2
        let liftB = 1 - liftA
        var body: [(gx: Int, gy: Int, w: Int, h: Int, c: NSColor)] = [
            // bean (rounded top/bottom), light left edge, dark right edge
            (5, 2, 10, 1, baseHi),
            (4, 3, 12, 1, base),
            (3, 4, 14, 10, base),
            (3, 4, 1, 10, baseHi),
            (15, 3, 1, 12, sideC),
            (16, 4, 1, 10, sideC),
            (4, 14, 12, 1, base),
            (5, 15, 10, 1, baseLo),
            // backpack (right = behind)
            (17, 5, 2, 1, sideC),
            (17, 6, 3, 6, sideC),
            (17, 12, 2, 1, baseLo),
        ]
        // legs: two chunky front + one hint of the far leg (depth)
        body.append((4, 16, 3, 2 - liftA + 1, base))
        body.append((4, 18 - liftA, 3, 1, baseLo))
        body.append((10, 16, 3, 2 - liftB + 1, base))
        body.append((10, 18 - liftB, 3, 1, baseLo))
        body.append((14, 16, 2, 2 - liftB, sideC))
        group(body)

        // ---- big Among Us visor (Claw'd's pixel eyes live inside) ----
        let sleeping = (p == .sleep)
        let g0 = sleeping ? glassLo : glass
        group([
            (3, 4, 9, 1, g0),
            (2, 5, 11, 3, g0),
            (3, 8, 9, 1, sleeping ? glassLo : glassLo),
            (3, 5, 4, 1, sleeping ? glassLo : glassHi),   // glare stripe
        ])

        // ---- pose props (each with its own outline = readable) ----
        switch p {
        case .idle:
            let wave = sin(t * 2.5) > 0.2 ? 2 : 0
            group([(0, 10 - wave, 2, 3, base), (0, 12 - wave, 2, 1, baseLo)])
        case .dance:
            let up = Int(t * 4) % 2
            group([(0, 3 + up, 2, 3, base)])
            group([(19, 4 - up, 2, 3, sideC)])
            let sp = NSColor(red: 1.0, green: 0.85, blue: 0.35, alpha: 1)
            if up == 0 { cell(2, 0, 1, 1, sp); cell(18, 1, 1, 1, sp); cell(0, 7, 1, 1, sp) }
            else { cell(4, 1, 1, 1, sp); cell(20, 0, 1, 1, sp); cell(21, 6, 1, 1, sp) }
        case .sleep:
            group([(0, 11, 2, 3, base), (0, 13, 2, 1, baseLo)])
            let phase = Int(t) % 3
            let zc = isDark ? NSColor(white: 0.92, alpha: 1) : inkC
            if phase >= 0 { ("z" as NSString).draw(at: gp(16.0, 3.0), withAttributes: [.font: pixelFont(7), .foregroundColor: zc]) }
            if phase >= 1 { ("z" as NSString).draw(at: gp(17.8, 1.4), withAttributes: [.font: pixelFont(8), .foregroundColor: zc]) }
            if phase >= 2 { ("Z" as NSString).draw(at: gp(19.4, -0.4), withAttributes: [.font: pixelFont(9), .foregroundColor: zc]) }
        case .read:
            let green = NSColor(red: 0.27, green: 0.62, blue: 0.33, alpha: 1)
            let greenDk = NSColor(red: 0.18, green: 0.44, blue: 0.24, alpha: 1)
            let page = NSColor(red: 0.97, green: 0.96, blue: 0.90, alpha: 1)
            group([
                (0, 10, 10, 6, green),
                (1, 11, 3, 3, page),
                (6, 11, 3, 3, page),
                (4, 10, 2, 6, greenDk),
            ])
            group([(9, 12, 2, 2, base)])   // claw hand on the book
        case .computer:
            let deck = NSColor(red: 0.36, green: 0.36, blue: 0.40, alpha: 1)
            let bezel = NSColor(red: 0.22, green: 0.22, blue: 0.26, alpha: 1)
            let screen = NSColor(red: 0.55, green: 0.76, blue: 0.95, alpha: 1)
            group([
                (0, 9, 9, 5, bezel),
                (1, 10, 7, 3, screen),
                (0, 14, 11, 2, deck),
            ])
            let cur = Int(t * 2) % 5
            cell(2 + cur, 11, 1, 1, NSColor(red: 0.20, green: 0.35, blue: 0.55, alpha: 1))
            group([(9, 13, 2, 2, base)])   // claw on the deck
        case .music:
            let blue = NSColor(red: 0.34, green: 0.45, blue: 0.76, alpha: 1)
            let blueDk = NSColor(red: 0.25, green: 0.33, blue: 0.58, alpha: 1)
            group([
                (5, 0, 10, 1, blue),
                (3, 1, 3, 1, blue), (14, 1, 3, 1, blueDk),
                (2, 2, 2, 4, blue),                 // near pad
                (16, 2, 2, 4, blueDk),              // far pad
            ])
            let hop = Int(t * 2) % 2
            let zc = isDark ? NSColor(white: 0.92, alpha: 1) : inkC
            ("♪" as NSString).draw(at: gp(19.2, CGFloat(2 - hop)), withAttributes: [.font: pixelFont(8), .foregroundColor: zc])
            ("♪" as NSString).draw(at: gp(17.4, CGFloat(4 - (1 - hop))), withAttributes: [.font: pixelFont(6), .foregroundColor: zc])
            group([(0, 9 - hop, 2, 3, base)])   // grooving claw
        case .camera:
            let camBody = NSColor(red: 0.17, green: 0.15, blue: 0.14, alpha: 1)
            let lens = NSColor(red: 0.55, green: 0.72, blue: 0.90, alpha: 1)
            group([
                (1, 5, 8, 4, camBody),
                (6, 4, 2, 1, NSColor(red: 0.32, green: 0.30, blue: 0.28, alpha: 1)),
                (1, 6, 2, 2, lens),
            ])
            group([(9, 7, 2, 2, base)])   // claw holding it
            if t.truncatingRemainder(dividingBy: 3.5) < 0.3 {
                let fl = NSColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1)
                cell(0, 0, 1, 1, fl); cell(2, 1, 1, 1, fl)
                cell(0, 2, 1, 1, fl); cell(1, 1, 1, 1, NSColor.white)
            }
        case .cook:
            let hatW = NSColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
            let hatLo = NSColor(red: 0.83, green: 0.83, blue: 0.87, alpha: 1)
            group([
                (5, 0, 9, 1, hatW),
                (4, 1, 11, 1, hatLo),
            ])
            let pan = NSColor(red: 0.26, green: 0.26, blue: 0.29, alpha: 1)
            let wood = NSColor(red: 0.48, green: 0.33, blue: 0.20, alpha: 1)
            group([
                (0, 12, 6, 2, pan),
                (6, 12, 2, 1, wood),
            ])
            // fried egg in the pan
            group([(1, 11, 3, 1, NSColor.white), (2, 11, 1, 1, NSColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 1))])
            group([(8, 11, 2, 2, base)])   // claw on the handle
            let s = Int(t * 3) % 3
            let steam = NSColor(white: isDark ? 0.85 : 0.50, alpha: 0.85)
            cell(1, 9 - s, 1, 1, steam)
            cell(4, 8 - ((s + 1) % 3), 1, 1, steam)
        }

        // ---- Claw'd's eyes inside the visor ----
        switch mood {
        case 0:
            let blink = t.truncatingRemainder(dividingBy: 3.4) > 3.2
            let closed = (p == .music || p == .sleep || p == .dance)
            let down = (p == .read) ? 1 : 0
            if p == .camera { break }   // face is behind the camera
            if blink || closed {
                cell(4, 6 + down, 2, 1, inkC)
                cell(8, 6 + down, 2, 1, inkC)
            } else {
                cell(4, 5 + down, 2, 2, inkC)
                cell(8, 5 + down, 2, 2, inkC)
            }
        case 1:
            cell(4, 6, 2, 1, inkC)
            cell(8, 6, 2, 1, inkC)
        default:
            cell(3, 4, 2, 1, inkC); cell(4, 5, 2, 1, inkC); cell(3, 6, 2, 1, inkC)
            cell(9, 4, 2, 1, inkC); cell(8, 5, 2, 1, inkC); cell(9, 6, 2, 1, inkC)
            let drip = Int(t * 5) % 5
            cell(14, drip, 1, 2, NSColor(red: 0.35, green: 0.66, blue: 0.94, alpha: 1))
        }
    }
}

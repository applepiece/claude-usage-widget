import Cocoa

struct AccountsResponse: Decodable {
    let accounts: [UsageAccount]
    let fetched_at: Double
}

struct UsageAccount: Decodable {
    let id: String
    let label: String
    var email: String?
    var plan: String?
    var source = "token"
    var machine_login = false
    var five_hour: LimitInfo?
    var seven_day: LimitInfo?
    var limits: [LimitInfo]?
    var state = "ok"
    var fetched_at: Double?
    var expires_at: String?
    var provider: String?
    var as_of: Double?
    var quota_source: String?

    var isCodex: Bool { provider == "codex" }
    var providerName: String { isCodex ? "Codex" : "Claude" }
    var failed: Bool { state == "error" || state == "token_rejected" }
    var usage: Usage {
        Usage(five_hour: five_hour, seven_day: seven_day, limits: limits,
              fetched_at: as_of ?? fetched_at, logged_in: true)
    }
    var info: AccountInfo {
        AccountInfo(logged_in: true, email: email, name: label, plan: plan, provider: provider)
    }
    var highest: Double? { [five_hour?.value, seven_day?.value].compactMap { $0 }.max() }
}

extension LimitInfo {
    var value: Double? {
        guard let value = utilization ?? percent, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

enum BarAccounts: String, CaseIterable { case primary, primarySecondary, all }
enum BarStyle: String, CaseIterable { case percent, battery, hp, dual, ring }
enum BarMetric: String, CaseIterable { case five, seven, both, max }

struct Preferences {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    func migrate() {
        guard !defaults.bool(forKey: "accountsV2Migrated") else { return }
        if let old = defaults.string(forKey: "barMode") {
            if old == "off" {
                defaults.set("percent", forKey: "barStyle")
                defaults.set(false, forKey: "barNumbers")
            } else if ["five", "seven", "both"].contains(old) {
                defaults.set(old, forKey: "barMetric")
            }
        }
        defaults.set(true, forKey: "accountsV2Migrated")
    }
    var primaryID: String? { defaults.string(forKey: "primaryAccount") }
    var secondaryID: String { defaults.string(forKey: "secondaryAccount") ?? "none" }
    var accounts: BarAccounts { BarAccounts(rawValue: defaults.string(forKey: "barAccounts") ?? "") ?? .primary }
    var style: BarStyle { BarStyle(rawValue: defaults.string(forKey: "barStyle") ?? "") ?? .battery }
    var metric: BarMetric { BarMetric(rawValue: defaults.string(forKey: "barMetric") ?? "") ?? .max }
    var numbers: Bool { defaults.object(forKey: "barNumbers") as? Bool ?? true }
    var always: Bool { defaults.object(forKey: "menuBarAlways") as? Bool ?? true }
    var twoWidgets: Bool { defaults.string(forKey: "widgetAccounts") == "primarySecondary" }

    func primary(in accounts: [UsageAccount]) -> UsageAccount? {
        accounts.first { $0.id == primaryID } ?? accounts.first { $0.machine_login } ?? accounts.first
    }
    func secondary(in accounts: [UsageAccount]) -> UsageAccount? {
        accounts.first { $0.id == secondaryID && $0.id != primary(in: accounts)?.id }
    }
    func shown(in accounts: [UsageAccount]) -> [UsageAccount] {
        if self.accounts == .all { return accounts }
        return [primary(in: accounts), self.accounts == .primarySecondary ? secondary(in: accounts) : nil].compactMap { $0 }
    }
}

func accountTags(_ accounts: [UsageAccount]) -> [String: String] {
    var tags: [String: String] = [:]
    for account in accounts {
        let first = String(account.label.prefix(1)).uppercased()
        let collide = accounts.filter {
            $0.isCodex == account.isCodex && String($0.label.prefix(1)).uppercased() == first
        }.count > 1
        tags[account.id] = (account.isCodex ? "›" : "") + String(account.label.prefix(collide ? 2 : 1)).uppercased()
    }
    var used = Set<String>()
    for account in accounts {
        let prefix = account.isCodex ? "›" : ""
        let label = account.label.uppercased()
        var tag = tags[account.id] ?? prefix
        var length = tag.count - prefix.count
        var suffix = 2
        while used.contains(tag) {
            if length < label.count {
                length += 1
                tag = prefix + String(label.prefix(length))
            } else {
                tag = prefix + label + String(suffix)
                suffix += 1
            }
        }
        used.insert(tag)
        tags[account.id] = tag
    }
    return tags
}

let usageGreen = NSColor(red: 0.19, green: 0.66, blue: 0.36, alpha: 1)
let usageAmber = NSColor(red: 0.87, green: 0.57, blue: 0.10, alpha: 1)
func powerColor(_ used: Double?) -> NSColor {
    guard let used else { return .secondaryLabelColor }
    return used >= 90 ? usageRed : (used >= 70 ? usageAmber : usageGreen)
}

// All status content is a single image. Measurements happen before drawing so
// five accounts stay below 160pt without scaling text to an unreadable size.
enum StatusRenderer {
    static func image(accounts: [UsageAccount], tags: [String: String], style: BarStyle,
                      metric: BarMetric, numbers: Bool, appearance: NSAppearance) -> NSImage {
        var result: NSImage!
        appearance.performAsCurrentDrawingAppearance {
            let ink = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            let tagFont = NSFont.systemFont(ofSize: 9, weight: .bold)
            func size(_ text: String, _ font: NSFont) -> CGFloat {
                ceil((text as NSString).size(withAttributes: [.font: font]).width)
            }
            // Percent has nothing but its numbers, so too many accounts first
            // drop the % signs, then fall back to each account's highest window.
            var compact = false
            var shownMetric = metric
            func values(_ account: UsageAccount) -> [Double?] {
                if account.failed { return [nil] }
                if style == .dual || style == .ring { return [account.five_hour?.value, account.seven_day?.value] }
                switch shownMetric {
                case .five: return [account.five_hour?.value]
                case .seven: return [account.seven_day?.value]
                case .both: return [account.five_hour?.value, account.seven_day?.value]
                case .max: return [account.highest]
                }
            }
            func text(_ account: UsageAccount) -> String {
                if account.failed { return "!" }
                let parts = values(account).map { $0.map { String(Int($0.rounded())) } ?? "–" }
                return parts.joined(separator: "·") + (!compact && parts.count == 1 && parts[0] != "–" ? "%" : "")
            }
            let baseGaugeWidth: CGFloat
            switch style {
            case .percent: baseGaugeWidth = 0
            case .battery: baseGaugeWidth = 25
            case .hp: baseGaugeWidth = 34
            case .dual: baseGaugeWidth = 26
            case .ring: baseGaugeWidth = 14
            }
            var gaugeWidth = baseGaugeWidth
            func width(showNumbers: Bool, spacing: CGFloat) -> CGFloat {
                24 + accounts.reduce(CGFloat(0)) { total, account in
                    let tag = accounts.count > 1 ? size(tags[account.id] ?? "?", tagFont) + 2 : 0
                    let label = showNumbers ? size(text(account), font) + (gaugeWidth > 0 ? 2 : 0) : 0
                    return total + spacing + tag + gaugeWidth + label
                }
            }
            var showNumbers = numbers
            if style == .percent, showNumbers {
                if width(showNumbers: true, spacing: accounts.count > 2 ? 3 : 5) >= 160 { compact = true }
                if width(showNumbers: true, spacing: accounts.count > 2 ? 3 : 5) >= 160 { shownMetric = .max }
            } else if width(showNumbers: showNumbers, spacing: 5) >= 160 { showNumbers = false }
            // Errors and absent metrics always need their textual state, even
            // when numbers are hidden; budget one small marker per gauge.
            func marker(_ a: UsageAccount) -> String {
                if a.failed { return "!" }
                if style == .dual || style == .ring {
                    return a.five_hour?.value == nil || a.seven_day?.value == nil ? "–" : ""
                }
                return values(a).contains(where: { $0 == nil }) ? "–" : ""
            }
            let spacing: CGFloat = accounts.count > 2 ? 3 : 5
            if !showNumbers, !accounts.isEmpty, style != .percent {
                let markerWidth = accounts.reduce(CGFloat(0)) { $0 + size(marker($1), font) }
                let overflow = max(0, width(showNumbers: false, spacing: spacing) + markerWidth - 158)
                gaugeWidth = max(8, gaugeWidth - overflow / CGFloat(accounts.count))
            }
            var imageWidth = width(showNumbers: showNumbers, spacing: spacing)
            if !showNumbers, style != .percent {
                imageWidth += accounts.reduce(0) { $0 + size(marker($1), font) }
            }
            let content = accounts
            let drawNumbers = showNumbers
            result = NSImage(size: NSSize(width: min(159, imageWidth), height: 22), flipped: false) { _ in
                NSGraphicsContext.current?.imageInterpolation = .none
                drawClawdGlyph(in: NSRect(x: 0, y: 3, width: 24, height: 17), color: ink)
                var x: CGFloat = 24
                func drawText(_ value: String, color: NSColor, font: NSFont) {
                    (value as NSString).draw(at: NSPoint(x: x, y: 5),
                                             withAttributes: [.font: font, .foregroundColor: color])
                    x += size(value, font)
                }
                func outline(_ rect: NSRect) {
                    ink.setStroke()
                    let path = NSBezierPath(rect: rect)
                    path.lineWidth = 1
                    path.stroke()
                }
                for account in content {
                    x += spacing
                    if content.count > 1 { drawText(tags[account.id] ?? "?", color: ink, font: tagFont); x += 2 }
                    let used = values(account).compactMap { $0 }.max()
                    let color = used == nil ? ink : powerColor(used)
                    let fraction = CGFloat(used ?? 0) / 100
                    NSGraphicsContext.saveGraphicsState()
                    let gaugeTransform = NSAffineTransform()
                    gaugeTransform.translateX(by: x, yBy: 0)
                    if baseGaugeWidth > 0 { gaugeTransform.scaleX(by: gaugeWidth / baseGaugeWidth, yBy: 1) }
                    gaugeTransform.translateX(by: -x, yBy: 0)
                    gaugeTransform.concat()
                    switch style {
                    case .percent: break
                    case .battery:
                        let box = NSRect(x: x + 0.5, y: 6.5, width: 21, height: 10)
                        outline(box)
                        ink.setFill(); NSRect(x: x + 22, y: 9, width: 2, height: 5).fill()
                        if !account.failed, used != nil {
                            color.setFill()
                            NSRect(x: x + 2, y: 8, width: 18 * (1 - fraction), height: 7).fill()
                        }
                    case .hp:
                        outline(NSRect(x: x + 0.5, y: 7.5, width: 33, height: 8))
                        if !account.failed, used != nil {
                            color.setFill()
                            for i in 0..<Int(ceil((100 - (used ?? 100)) / 10)) {
                                NSRect(x: x + 2 + CGFloat(i) * 3, y: 9, width: 2, height: 5).fill()
                            }
                        }
                    case .dual:
                        for (index, window) in [account.five_hour, account.seven_day].enumerated() {
                            let y: CGFloat = index == 0 ? 13 : 6
                            outline(NSRect(x: x + 0.5, y: y + 0.5, width: 25, height: 3))
                            if !account.failed, let v = window?.value {
                                (index == 0 ? usageOrange : usagePurple).setFill()
                                NSRect(x: x + 1, y: y + 1, width: 24 * CGFloat(v) / 100, height: 2).fill()
                            }
                        }
                    case .ring:
                        for (index, window) in [account.five_hour, account.seven_day].enumerated() {
                            let radius: CGFloat = index == 0 ? 6 : 3
                            let center = NSPoint(x: x + 7, y: 11)
                            ink.withAlphaComponent(0.35).setStroke()
                            let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                                   width: radius * 2, height: radius * 2))
                            track.lineWidth = 1.5; track.stroke()
                            if !account.failed, let v = window?.value, v > 0 {
                                (index == 0 ? usageOrange : usagePurple).setStroke()
                                let arc = NSBezierPath()
                                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                                              endAngle: 90 - CGFloat(v) * 3.6, clockwise: true)
                                arc.lineWidth = 1.5; arc.stroke()
                            }
                        }
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    x += gaugeWidth
                    if drawNumbers {
                        if gaugeWidth > 0 { x += 2 }
                        drawText(text(account), color: style == .percent ? ink : color, font: font)
                    } else if style != .percent {
                        drawText(marker(account), color: ink, font: font)
                    }
                }
                return true
            }
        }
        result.isTemplate = false
        return result
    }
}

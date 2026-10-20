import Foundation

/// Pure text and compaction rules shared by the status button and its previews.
public struct StatusTitle: Sendable {
    public struct Segment: Equatable, Sendable {
        public let accountID: String
        public let shortName: String
        public let value: String
        public var string: String { shortName + " " + value }
    }

    public let segments: [Segment]
    public let hiddenCount: Int
    public let string: String
    public let accessibilityLabel: String

    public init(accounts: [UsageAccount], shortNames: [String: String] = [:],
                metric: BarMetric = .max, numbers: Bool = true) {
        let names = AccountShortNames.effective(in: accounts, custom: shortNames)
        var shownMetric = metric
        func makeSegments(percent: Bool) -> [Segment] {
            accounts.map { account in
                Segment(accountID: account.id, shortName: names[account.id] ?? "?",
                        value: Self.value(account, metric: shownMetric, percent: percent))
            }
        }
        func joined(_ segments: [Segment]) -> String { segments.map(\.string).joined(separator: "  ") }
        var visible = numbers ? makeSegments(percent: true) : []
        if joined(visible).count > 28 { visible = makeSegments(percent: false) }
        if joined(visible).count > 28 {
            shownMetric = .max
            visible = makeSegments(percent: false)
        }
        var hidden = 0
        if joined(visible).count > 28, visible.count > 1 {
            hidden = visible.count - 1
            visible = Array(visible.prefix(1))
        }
        segments = visible
        hiddenCount = hidden
        string = joined(visible) + (hidden > 0 ? "  +\(hidden)" : "")
        accessibilityLabel = accounts.isEmpty ? "Claude Usage, no accounts" : accounts.map { account in
            (names[account.id] ?? "?") + ", " + Self.accessibilityValue(account, metric: shownMetric)
        }.joined(separator: ", ")
    }

    private static func value(_ account: UsageAccount, metric: BarMetric, percent: Bool) -> String {
        if account.failed { return "!" }
        func number(_ value: Double?) -> String {
            value.map { String(Int($0.rounded())) + (percent && metric != .both ? "%" : "") } ?? "–"
        }
        switch metric {
        case .five: return number(account.fiveHour?.value)
        case .seven: return number(account.sevenDay?.value)
        case .both: return number(account.fiveHour?.value) + "·" + number(account.sevenDay?.value)
        case .max: return number(account.highest)
        }
    }

    private static func accessibilityValue(_ account: UsageAccount, metric: BarMetric) -> String {
        if account.state == .tokenRejected { return "sign-in expired" }
        if account.failed { return "couldn't load usage" }
        func window(_ value: Double?, _ name: String) -> String {
            value.map { "\(Int($0.rounded())) percent used, \(name)" } ?? "usage unavailable, \(name)"
        }
        switch metric {
        case .five: return window(account.fiveHour?.value, "session")
        case .seven: return window(account.sevenDay?.value, "weekly")
        case .both:
            return window(account.fiveHour?.value, "session") + ", " + window(account.sevenDay?.value, "weekly")
        case .max:
            guard let highest = account.highest else { return "usage unavailable" }
            return window(highest, account.fiveHour?.value == highest ? "session" : "weekly")
        }
    }
}

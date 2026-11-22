import Foundation

public enum UsageMetricColor: String, Hashable, Sendable {
    case orange, purple, teal, pink, blue, brown, green
}

public enum UsageMetric: Hashable, Sendable {
    case session
    case weekly
    case weeklyModel(String)
    case extraUsage

    public static let defaultSlots: [UsageMetric] = [.session, .weekly]

    public init?(raw: String) {
        switch raw {
        case "session": self = .session
        case "weekly": self = .weekly
        case "extra": self = .extraUsage
        default:
            guard raw.hasPrefix("weekly:") else { return nil }
            let model = String(raw.dropFirst("weekly:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return nil }
            self = .weeklyModel(model)
        }
    }

    public var raw: String {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        case .weeklyModel(let model): "weekly:" + model
        case .extraUsage: "extra"
        }
    }

    public var title: String {
        switch self {
        case .session: MenuFormatting.limitName(LimitInfo(kind: "session"))
        case .weekly: MenuFormatting.limitName(LimitInfo(kind: "weekly_all"))
        case .weeklyModel(let model):
            MenuFormatting.limitName(LimitInfo(kind: "weekly_scoped", scope: LimitScope(model: LimitModel(displayName: model))))
        case .extraUsage: String(localized: "Extra usage")
        }
    }

    public var shortTitle: String {
        switch self {
        case .session: String(localized: "5h")
        case .weekly: String(localized: "Week")
        case .weeklyModel(let model): model
        case .extraUsage: String(localized: "Extra")
        }
    }

    public var colorKey: UsageMetricColor {
        switch self {
        case .session: .orange
        case .weekly: .purple
        case .weeklyModel(let model):
            switch model.lowercased() {
            case "fable": .teal
            case "opus": .pink
            case "sonnet": .blue
            default: .brown
            }
        case .extraUsage: .green
        }
    }

    /// Choose a label at the normal font size after reserving space for the percentage.
    public func widgetLabel(reset: String, accountTag: String = "", availableWidth: Double,
                            measure: (String) -> Double) -> String {
        let title = shortTitle.uppercased()
        let prefix: String
        switch self {
        case .session, .weekly: prefix = ""
        case .weeklyModel, .extraUsage: prefix = title
        }
        func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " ") }
        var candidates = [joined([prefix, accountTag, reset])]
        let words = reset.split(separator: " ")
        if words.count > 1, words.last?.contains(":") == true {
            candidates.append(joined([prefix, accountTag, words.dropLast().joined(separator: " ")]))
        }
        candidates.append(title)
        if let fitting = candidates.first(where: { measure($0) <= availableWidth }) { return fitting }
        // Unusually long model names must still leave the percentage unobstructed.
        guard measure("…") <= availableWidth else { return "" }
        var shortened = title
        while !shortened.isEmpty, measure(shortened + "…") > availableWidth { shortened.removeLast() }
        return shortened + "…"
    }

    // Model spelling is preserved for display and storage, but identifies one slot regardless of case.
    public static func == (lhs: UsageMetric, rhs: UsageMetric) -> Bool { lhs.raw.lowercased() == rhs.raw.lowercased() }
    public func hash(into hasher: inout Hasher) { hasher.combine(raw.lowercased()) }

    public func limit(for account: UsageAccount) -> LimitInfo? {
        switch self {
        case .session: account.fiveHour ?? account.limits?.first { $0.kind == "session" }
        case .weekly: account.sevenDay ?? account.limits?.first { $0.kind == "weekly_all" }
        case .weeklyModel(let model):
            account.limits?.first {
                $0.kind == "weekly_scoped" && $0.scope?.model?.displayName?.caseInsensitiveCompare(model) == .orderedSame
            }
        case .extraUsage: account.limits?.first { $0.kind == "extra_usage" }
        }
    }

    public func value(for account: UsageAccount) -> (percent: Double, resetsAt: Date?)? {
        guard let limit = limit(for: account), let percent = limit.value else { return nil }
        let reset = limit.resetsAt.flatMap(parseISO)
        return (percent, reset)
    }

    public static func available(in accounts: [UsageAccount]) -> [UsageMetric] {
        var metrics: [UsageMetric] = [.session, .weekly]
        let discovered = accounts.flatMap { $0.limits ?? [] }.compactMap { limit in
            limit.kind == "weekly_scoped" ? limit.scope?.model?.displayName : nil
        }
        for name in ["Fable", "Opus", "Sonnet"] + discovered {
            guard let metric = UsageMetric(raw: "weekly:" + name), !metrics.contains(metric) else { continue }
            metrics.append(metric)
        }
        return metrics + [.extraUsage]
    }
}

/// Shared geometry keeps menu columns and stacked widget sizing independent of AppKit.
public enum UsageBarLayout {
    public static func menuColumnStops(count: Int) -> [Double] {
        let count = min(3, max(1, count))
        return (0..<count).map { 264 - Double(count - 1 - $0) * 54 }
    }

    public static func widgetHeight(count: Int) -> Double {
        // A single row still reserves room for the unscaled mascot; two rows retain the original 74pt height.
        max(64, 10 + Double(min(3, max(1, count))) * 32)
    }

    public static func widgetBarOrigins(count: Int) -> [Double] {
        (0..<min(3, max(1, count))).map { widgetHeight(count: count) - 32 - Double($0) * 32 }
    }

    public static func widgetFrame(origin: CGPoint, barCount: Int, widgetCount: Int) -> CGRect {
        CGRect(origin: origin, size: CGSize(width: 216, height: widgetHeight(count: barCount) * Double(min(2, max(1, widgetCount)))))
    }

    public static func resizedWidgetFrame(_ frame: CGRect, barCount: Int, widgetCount: Int) -> CGRect {
        var resized = widgetFrame(origin: frame.origin, barCount: barCount, widgetCount: widgetCount)
        resized.origin.y = frame.maxY - resized.height
        return resized
    }

    public static func moodSeverity(for account: UsageAccount?) -> Int {
        let percent = max(account?.fiveHour?.value ?? 0, account?.sevenDay?.value ?? 0)
        return percent >= 90 ? 2 : (percent >= 70 ? 1 : 0)
    }
}

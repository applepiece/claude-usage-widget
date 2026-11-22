import Foundation

public struct CreditsResponse: Decodable, Sendable {
    public let providers: [CreditProvider]
    // A missing config returns only an empty providers array.
    public let updatedAt: Double?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case providers, error
        case updatedAt = "updated_at"
    }
}

public enum CreditSpendSource: String, Decodable, Sendable {
    case costsAPI = "costs_api"
    case ledger
    case ledgerPartial = "ledger_partial"
}

public struct CreditExpiry: Decodable, Sendable {
    public let date: String
    public let amount: Double

    public init(date: String, amount: Double) {
        self.date = date
        self.amount = amount
    }
}

public struct CreditProvider: Decodable, Sendable, Identifiable {
    public let id: String
    public let type: String?
    public let label: String
    public let remaining: Double?
    public let granted: Double?
    public let spentSinceAnchor: Double?
    public let spendSource: CreditSpendSource?
    public let anchorAt: String?
    public let nextExpiry: CreditExpiry?
    public let console: String?
    public let staleDays: Int?
    public let note: String?
    public let extra: Double?
    public let error: String?

    public init(id: String, type: String? = nil, label: String, remaining: Double, granted: Double,
                spentSinceAnchor: Double = 0, spendSource: CreditSpendSource = .ledger,
                anchorAt: String, nextExpiry: CreditExpiry? = nil, console: String,
                staleDays: Int = 0, note: String? = nil, extra: Double? = nil, error: String? = nil) {
        self.id = id
        self.type = type
        self.label = label
        self.remaining = remaining
        self.granted = granted
        self.spentSinceAnchor = spentSinceAnchor
        self.spendSource = spendSource
        self.anchorAt = anchorAt
        self.nextExpiry = nextExpiry
        self.console = console
        self.staleDays = staleDays
        self.note = note
        self.extra = extra
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id, type, label, remaining, granted, console, note, extra, error
        case spentSinceAnchor = "spent_since_anchor"
        case spendSource = "spend_source"
        case anchorAt = "anchor_at"
        case nextExpiry = "next_expiry"
        case staleDays = "stale_days"
    }

    public var providerType: String { type ?? id }

    public var hasBalance: Bool {
        error == nil && remaining?.isFinite == true && granted?.isFinite == true
    }

    public var consoleURL: URL? { CreditFormatting.consoleURL(console) }

    public var glyphProvider: Provider? {
        switch type {
        case "anthropic": return .claude
        case "openai": return .codex
        default: return nil
        }
    }
}

/// Pure sample data shared by QA mode, menu previews and regression tests.
public enum CreditSamples {
    public static func providers(now: Date = Date()) -> [CreditProvider] {
        let iso = ISO8601DateFormatter()
        let anchor = iso.string(from: now)
        let expiry = iso.string(from: now.addingTimeInterval(18 * 86400))
        return [
            CreditProvider(id: "anthropic", type: "anthropic", label: "Claude API · kkpk", remaining: 199.52, granted: 200,
                           spentSinceAnchor: 0.48, anchorAt: anchor,
                           nextExpiry: CreditExpiry(date: expiry, amount: 199.52),
                           console: "https://platform.claude.com/settings/billing", extra: 9.07),
            CreditProvider(id: "anthropic_pho", type: "anthropic", label: "Claude API · pho", remaining: 24, granted: 200,
                           spentSinceAnchor: 176, spendSource: .ledgerPartial, anchorAt: anchor,
                           nextExpiry: CreditExpiry(date: expiry, amount: 24),
                           console: "https://platform.claude.com/settings/billing", extra: 0),
            CreditProvider(id: "openai", type: "openai", label: "OpenAI API", remaining: 90.08, granted: 111,
                           spentSinceAnchor: 20.92, spendSource: .costsAPI, anchorAt: anchor,
                           nextExpiry: CreditExpiry(date: iso.string(from: now.addingTimeInterval(2 * 86400)), amount: 28.66),
                           console: "https://platform.openai.com/settings/organization/billing/credit-grants"),
        ]
    }
}

/// A failed response preserves the snapshot and the time of its last success.
public struct CreditSnapshot: Sendable {
    public var providers: [CreditProvider]
    public var updatedAt: Date?

    public init(providers: [CreditProvider] = [], updatedAt: Date? = nil) {
        self.providers = providers
        self.updatedAt = updatedAt
    }

    public mutating func receive(_ response: CreditsResponse?, now: Date) {
        guard let response, response.error == nil else { return }
        providers = response.providers
        updatedAt = now
    }
}

/// Shared visible and spoken text prevents estimates losing their qualification.
public struct CreditRowPresentation: Sendable {
    public let provider: CreditProvider
    public let shortLabel: String
    public let amount: String
    public let detailItems: [String]
    public let annotation: String
    public let detail: String
    public let showsMeter: Bool
    public let fraction: Double
    public let warningReason: CreditWarning?
    public let stale: Bool
    public var warning: Bool { warningReason != nil }
    public var unavailable: Bool { !provider.hasBalance }

    public init(_ provider: CreditProvider, updatedAt: Date?, now: Date,
                warnDays: Int = 7, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.provider = provider
        shortLabel = Self.shortLabel(provider.label)
        stale = CreditFormatting.isStale(updatedAt: updatedAt, now: now)
        detailItems = CreditFormatting.detailItems(provider, updatedAt: updatedAt, now: now, locale: locale, timeZone: timeZone)
        if provider.hasBalance, let remaining = provider.remaining, let granted = provider.granted {
            amount = CreditFormatting.amount(remaining, partial: provider.spendSource == .ledgerPartial)
            showsMeter = granted > 0
            fraction = CreditFormatting.fraction(remaining: remaining, granted: granted)
            warningReason = CreditFormatting.warningReason(remaining: remaining, granted: granted, expiry: provider.nextExpiry,
                                                           now: now, warnDays: warnDays, timeZone: timeZone)
            var annotations: [String] = []
            if let anchor = provider.anchorAt, let date = CreditFormatting.date(anchor),
               (provider.staleDays ?? 0) >= 7 || now.timeIntervalSince(date) >= 7 * 86400 {
                let shortDate = CreditFormatting.shortDate(date, locale: locale, timeZone: timeZone)
                annotations.append(String(localized: "balance from \(shortDate)", locale: locale))
            }
            if stale { annotations.append(String(localized: "Balance update overdue", locale: locale)) }
            annotation = annotations.joined(separator: " · ")
        } else {
            amount = "—"
            annotation = provider.error ?? String(localized: "Invalid balance", locale: locale)
            showsMeter = false
            fraction = 0
            warningReason = nil
        }
        detail = ([shortLabel, amount] + detailItems + [annotation, provider.note])
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func shortLabel(_ label: String) -> String {
        let fallback = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { return String(localized: "API credits") }
        guard label.range(of: #"\bAPI\b"#, options: .regularExpression) != nil else { return label }
        let shortened = label.replacingOccurrences(of: #"\s*\bAPI\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened.isEmpty ? fallback : shortened
    }
}

public enum CreditWarning: Equatable, Sendable {
    case expiry(days: Int, amount: Double)
    case lowBalance(percent: Int)
}

/// Owns section visibility and row placement so all display modes are testable without AppKit.
public struct CreditsMenuPresentation: Sendable {
    public let display: CreditsDisplay
    public let totalRemaining: Double
    public let totalAmount: String
    public let rows: [CreditRowPresentation]
    public let warning: String?

    public var mainRows: [CreditRowPresentation] { display == .providers ? rows : [] }
    public var submenuRows: [CreditRowPresentation] { display == .total ? rows : [] }
    public var showsSection: Bool { display != .off }
    public var structure: CreditMenuStructure { CreditMenuStructure(display: display, providerIDs: rows.map { $0.provider.id }) }

    /// Measure complete amount strings with the renderer's font, including estimates and errors.
    public func amountColumnWidth(measure: (String) -> Double) -> Double {
        rows.reduce(0) { max($0, measure($1.amount)) }
    }

    public init(providers: [CreditProvider], display: CreditsDisplay, updatedAt: Date?, now: Date,
                warnDays: Int = 7, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.display = providers.isEmpty ? .off : display
        let healthy = providers.filter(\.hasBalance)
        totalRemaining = healthy.reduce(0) { $0 + max(0, $1.remaining ?? 0) }
        let total = healthy.isEmpty ? "—" :
            CreditFormatting.amountLeft(totalRemaining, partial: healthy.contains { $0.spendSource == .ledgerPartial }, locale: locale)
        let unavailable = providers.count - healthy.count
        totalAmount = total + (unavailable > 0 ? String(localized: " · \(unavailable) unavailable", locale: locale) : "")
        rows = self.display == .off ? [] : providers.map {
            CreditRowPresentation($0, updatedAt: updatedAt, now: now, warnDays: warnDays, locale: locale, timeZone: timeZone)
        }
        let warnings = rows.filter(\.warning)
        // Imminent expiries come first, then the lowest remaining fraction.
        let urgent = warnings.min { lhs, rhs in
            switch (lhs.warningReason, rhs.warningReason) {
            case let (.expiry(left, _), .expiry(right, _)): return left < right
            case (.expiry, _): return true
            case (_, .expiry): return false
            default: return lhs.fraction < rhs.fraction
            }
        }
        if let urgent, let reason = urgent.warningReason {
            let text: String
            switch reason {
            case let .expiry(days, amount):
                let value = CreditFormatting.amount(amount, partial: urgent.provider.spendSource == .ledgerPartial)
                switch days {
                case 0: text = String(localized: "\(urgent.shortLabel): \(value) expires today", locale: locale)
                case 1: text = String(localized: "\(urgent.shortLabel): \(value) expires tomorrow", locale: locale)
                default: text = String(localized: "\(urgent.shortLabel): \(value) expires in \(days) days", locale: locale)
                }
            case let .lowBalance(percent):
                text = String(localized: "\(urgent.shortLabel): \(percent)% left", locale: locale)
            }
            let more = warnings.count - 1
            warning = more > 0 ? text + String(localized: " · +\(more) more", locale: locale) : text
        } else {
            warning = nil
        }
    }
}

/// USD balances and localized expiry dates, independent of AppKit and wall time.
public enum CreditFormatting {
    public static func amount(_ remaining: Double, partial: Bool = false) -> String {
        (partial ? "≤" : "") + dollars(remaining, fixedDecimals: true)
    }

    public static func consoleURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func amountLeft(_ remaining: Double, partial: Bool = false, locale: Locale = .current) -> String {
        let value = amount(remaining, partial: partial)
        return String(localized: "\(value) left", locale: locale)
    }

    public static func subtitle(granted: Double, expiry: CreditExpiry?, locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String {
        guard granted > 0 else { return "" }
        let amount = dollars(granted, fixedDecimals: false)
        guard let expiry, let date = date(expiry.date) else {
            return String(localized: "of \(amount)", locale: locale)
        }
        let expiring = dollars(expiry.amount, fixedDecimals: false)
        let shortDate = shortDate(date, locale: locale, timeZone: timeZone)
        return String(localized: "of \(amount) · \(expiring) expires \(shortDate)", locale: locale)
    }

    public static func fraction(remaining: Double, granted: Double) -> Double {
        guard remaining.isFinite, granted.isFinite, granted > 0 else { return 0 }
        return min(1, max(0, remaining / granted))
    }

    public static func warning(remaining: Double, granted: Double, expiry: String?, now: Date,
                               warnDays: Int = 7, timeZone: TimeZone = .current) -> Bool {
        warningReason(remaining: remaining, granted: granted,
                      expiry: expiry.map { CreditExpiry(date: $0, amount: remaining) },
                      now: now, warnDays: warnDays, timeZone: timeZone) != nil
    }

    public static func warningReason(remaining: Double, granted: Double, expiry: CreditExpiry?, now: Date,
                                     warnDays: Int = 7, timeZone: TimeZone = .current) -> CreditWarning? {
        if let expiry, expiry.amount.isFinite, expiry.amount > 0, let date = date(expiry.date), date >= now {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: date)).day ?? 0
            if days <= warnDays { return .expiry(days: days, amount: expiry.amount) }
        }
        if granted > 0, remaining.isFinite, granted.isFinite, remaining / granted < 0.20 {
            return .lowBalance(percent: Int((fraction(remaining: remaining, granted: granted) * 100).rounded()))
        }
        return nil
    }

    public static func detailItems(_ provider: CreditProvider, updatedAt: Date?, now: Date,
                                   locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        var items: [String] = []
        if let granted = provider.granted, granted.isFinite {
            let value = amount(granted)
            items.append(String(localized: "Granted \(value)", locale: locale))
        }
        if let spent = provider.spentSinceAnchor, spent.isFinite,
           let anchor = provider.anchorAt.flatMap(date) {
            let day = shortDate(anchor, locale: locale, timeZone: timeZone)
            let value = amount(spent)
            items.append(String(localized: "Used since \(day)  \(value)", locale: locale))
        }
        if let expiry = provider.nextExpiry, expiry.amount.isFinite, let date = date(expiry.date) {
            let day = shortDate(date, locale: locale, timeZone: timeZone)
            let value = amount(expiry.amount)
            items.append(date < now ? String(localized: "Expired \(day)", locale: locale) :
                         String(localized: "Next expiry \(day)  \(value)", locale: locale))
        }
        if let extra = provider.extra, extra.isFinite, extra > 0 {
            let value = amount(extra)
            items.append(String(localized: "Purchased balance \(value)", locale: locale))
        }
        switch provider.spendSource {
        case .ledger, .ledgerPartial: items.append(String(localized: "Source: bridge ledger", locale: locale))
        case .costsAPI: items.append(String(localized: "Source: OpenAI costs API", locale: locale))
        case nil: break
        }
        if let updatedAt { items.append(MenuFormatting.updated(since: updatedAt, now: now)) }
        return items
    }

    public static func isStale(updatedAt: Date?, now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) >= 30 * 60
    }

    private static func dollars(_ value: Double, fixedDecimals: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fixedDecimals ? 2 : 0
        formatter.maximumFractionDigits = 2
        let safe = value.isFinite ? max(0, value) : 0
        return "$" + (formatter.string(from: NSNumber(value: safe)) ?? "0")
    }

    fileprivate static func shortDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date)
    }

    fileprivate static func date(_ value: String) -> Date? {
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 7 * 3600)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: value)
        }
        return parseISO(value)
    }
}

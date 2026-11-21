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
            CreditProvider(id: "anthropic", type: "anthropic", label: "Claude API · kkpk", remaining: 199.95, granted: 200,
                           spentSinceAnchor: 0.05, anchorAt: anchor,
                           nextExpiry: CreditExpiry(date: expiry, amount: 199.95),
                           console: "https://platform.claude.com/settings/billing", extra: 9.07),
            CreditProvider(id: "anthropic_pho", type: "anthropic", label: "Claude API · pho", remaining: 200, granted: 200,
                           anchorAt: anchor, nextExpiry: CreditExpiry(date: expiry, amount: 200),
                           console: "https://platform.claude.com/settings/billing", extra: 0),
            CreditProvider(id: "openai", type: "openai", label: "OpenAI API", remaining: 5.25, granted: 100,
                           spentSinceAnchor: 94.75, spendSource: .costsAPI, anchorAt: anchor,
                           nextExpiry: CreditExpiry(date: iso.string(from: now.addingTimeInterval(2 * 86400)), amount: 5.25),
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
    public let amount: String
    public let subtitle: String
    public let annotation: String
    public let detail: String
    public let showsMeter: Bool
    public let fraction: Double
    public let warning: Bool
    public let stale: Bool

    public init(_ provider: CreditProvider, updatedAt: Date?, now: Date,
                locale: Locale = .current, timeZone: TimeZone = .current) {
        stale = CreditFormatting.isStale(updatedAt: updatedAt, now: now)
        if provider.error == nil, let remaining = provider.remaining, let granted = provider.granted {
            amount = CreditFormatting.amountLeft(remaining, partial: provider.spendSource == .ledgerPartial, locale: locale)
            subtitle = CreditFormatting.subtitle(granted: granted, expiry: provider.nextExpiry, locale: locale, timeZone: timeZone)
            showsMeter = granted > 0
            fraction = CreditFormatting.fraction(remaining: remaining, granted: granted)
            warning = CreditFormatting.warning(remaining: remaining, granted: granted, expiry: provider.nextExpiry?.date, now: now)
            var annotations: [String] = []
            if let anchor = provider.anchorAt, let date = CreditFormatting.date(anchor),
               (provider.staleDays ?? 0) >= 7 || now.timeIntervalSince(date) >= 7 * 86400 {
                let shortDate = CreditFormatting.shortDate(date, locale: locale, timeZone: timeZone)
                annotations.append(String(localized: "balance from \(shortDate)", locale: locale))
            }
            if stale { annotations.append(String(localized: "Balance update overdue", locale: locale)) }
            annotation = annotations.joined(separator: " · ")
        } else {
            amount = String(localized: "Unavailable", locale: locale)
            subtitle = ""
            annotation = provider.error ?? String(localized: "Invalid balance", locale: locale)
            showsMeter = false
            fraction = 0
            warning = false
        }
        detail = [provider.label, amount, subtitle, annotation, provider.note]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// USD balances and localized expiry dates, independent of AppKit and wall time.
public enum CreditFormatting {
    public static func amountLeft(_ remaining: Double, partial: Bool = false, locale: Locale = .current) -> String {
        let amount = dollars(remaining, fixedDecimals: true)
        return (partial ? "≤ " : "") + String(localized: "\(amount) left", locale: locale)
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

    public static func warning(remaining: Double, granted: Double, expiry: String?, now: Date) -> Bool {
        guard granted > 0 else { return false }
        if fraction(remaining: remaining, granted: granted) < 0.10 { return true }
        guard let expiry, let date = date(expiry) else { return false }
        return date.timeIntervalSince(now) <= 3 * 86400
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
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

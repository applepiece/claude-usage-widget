import Foundation

/// Text shared by the native menu and Settings. All time inputs are injectable.
public enum MenuFormatting {
    public static func planTitle(_ plan: String?) -> String? {
        let words = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        switch words {
        case "max": return String(localized: "Max")
        case "pro": return String(localized: "Pro")
        case "team": return String(localized: "Team")
        case "edu": return String(localized: "Edu")
        case "pro lite": return String(localized: "Pro Lite")
        case "free": return String(localized: "Free")
        case "plus": return String(localized: "Plus")
        case "enterprise": return String(localized: "Enterprise")
        case "business": return String(localized: "Business")
        default: return nil
        }
    }

    public static func limitName(_ limit: LimitInfo) -> String {
        switch limit.kind {
        case "session": return String(localized: "Current session")
        case "weekly_all": return String(localized: "Weekly · All models")
        case "weekly_scoped":
            if let name = limit.scope?.model?.displayName, !name.isEmpty {
                return String(localized: "Weekly · \(name)")
            }
            return String(localized: "Weekly · Scoped")
        case .some(let kind) where !kind.isEmpty:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        default: return String(localized: "Usage limit")
        }
    }

    public static func resetCaption(value: Double?, reset: Date?, now: Date,
                                    calendar: Calendar = .current, locale: Locale = .current,
                                    timeZone: TimeZone = .current) -> String {
        guard let value else { return String(localized: "Not reported for this plan") }
        guard let reset else {
            return value == 0 ? String(localized: "Not started") : String(localized: "Reset time unavailable")
        }
        let remaining = max(0, reset.timeIntervalSince(now))
        if remaining < 60 { return String(localized: "Resets in under a minute") }
        var calendar = calendar
        calendar.timeZone = timeZone
        let english = Locale(identifier: "en_" + (locale.region?.identifier ?? "US"))
        if remaining < 86400 {
            calendar.locale = english
            let formatter = DateComponentsFormatter()
            formatter.calendar = calendar
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
            formatter.zeroFormattingBehavior = .dropAll
            let duration = formatter.string(from: floor(remaining / 60) * 60) ?? ""
            return String(localized: "Resets in \(duration)")
        }
        let formatter = DateFormatter()
        formatter.locale = english
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        // Keep English weekday names while respecting the caller's hour cycle,
        // including a user's override of their region's usual clock format.
        let preferred = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        let generated = formatter.dateFormat ?? ""
        if preferred.contains("H") && generated.contains("h") {
            formatter.setLocalizedDateFormatFromTemplate("EEEHHmm")
        } else if preferred.contains("h") && generated.contains("H") {
            formatter.setLocalizedDateFormatFromTemplate("EEEhmm")
        }
        return String(localized: "Resets \(formatter.string(from: reset))")
    }

    public static func timestamp(_ account: UsageAccount) -> Date? {
        [account.fetchedAt, account.asOf].compactMap { $0 }.filter(\.isFinite).max()
            .map { Date(timeIntervalSince1970: $0) }
    }

    public static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60)) min") }
        if seconds < 86400 { return String(localized: "\(Int(seconds / 3600)) hr") }
        if seconds < 172800 { return String(localized: "1 day") }
        return String(localized: "\(Int(seconds / 86400)) days")
    }

    public static func updated(since date: Date?, now: Date) -> String {
        guard let date else { return String(localized: "Not updated yet") }
        if now.timeIntervalSince(date) < 60 { return String(localized: "Updated just now") }
        return String(localized: "Updated \(age(since: date, now: now)) ago")
    }

    public static func accountSubtitle(_ account: UsageAccount, now: Date) -> String {
        if account.state == .tokenRejected { return String(localized: "Sign-in expired") }
        if account.state == .error { return String(localized: "Couldn't load usage") }
        var parts = [planTitle(account.plan)].compactMap { $0 }
        if let value = account.fiveHour?.value {
            parts.append(String(localized: "Session \(Int(value.rounded()))%"))
        }
        if let value = account.sevenDay?.value {
            parts.append(String(localized: "Weekly \(Int(value.rounded()))%"))
        }
        if account.state == .stale {
            if let date = timestamp(account) {
                parts.append(String(localized: "\(age(since: date, now: now)) old"))
            } else { parts.append(String(localized: "Stale")) }
        }
        return parts.joined(separator: " · ")
    }
}

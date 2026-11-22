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
        case "session": return String(localized: "Session")
        case "weekly_all": return String(localized: "Weekly")
        case "weekly_scoped":
            if let name = limit.scope?.model?.displayName, !name.isEmpty {
                return String(localized: "Weekly \(name)")
            }
            return String(localized: "Weekly scoped")
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
        let text = shortResetText(value: value, reset: reset, now: now,
                                  calendar: calendar, locale: locale, timeZone: timeZone)
        return remaining < 86400 ? String(localized: "Resets in \(text)") : String(localized: "Resets \(text)")
    }

    public static func shortResetText(value: Double?, reset: Date?, now: Date,
                                      calendar: Calendar = .current, locale: Locale = .current,
                                      timeZone: TimeZone = .current) -> String {
        guard value != nil, let reset else { return "" }
        let remaining = max(0, reset.timeIntervalSince(now))
        if remaining < 60 { return "<1m" }
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
            return formatter.string(from: floor(remaining / 60) * 60) ?? ""
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
        return formatter.string(from: reset)
    }

    /// Spoken help keeps the meaning that is omitted from the compact visual row.
    public static func resetHelp(value: Double?, reset: Date?, now: Date,
                                 calendar: Calendar = .current, locale: Locale = .current,
                                 timeZone: TimeZone = .current) -> String {
        guard value != nil, let reset else {
            return resetCaption(value: value, reset: reset, now: now,
                                calendar: calendar, locale: locale, timeZone: timeZone)
        }
        let minutes = Int(max(0, reset.timeIntervalSince(now)) / 60)
        guard (1..<1440).contains(minutes) else {
            return resetCaption(value: value, reset: reset, now: now,
                                calendar: calendar, locale: locale, timeZone: timeZone)
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        var parts: [String] = []
        if hours == 1 { parts.append(String(localized: "1 hour")) }
        else if hours > 1 { parts.append(String(localized: "\(hours) hours")) }
        if remainder == 1 { parts.append(String(localized: "1 minute")) }
        else if remainder > 1 { parts.append(String(localized: "\(remainder) minutes")) }
        return String(localized: "Resets in \(parts.joined(separator: " "))")
    }

    public static func failedRowText(_ state: AccountState) -> String? {
        switch state {
        case .tokenRejected: return String(localized: "⚠︎ expired")
        case .error: return String(localized: "⚠︎ error")
        case .ok, .stale: return nil
        }
    }

    @MainActor
    public static func accountTooltip(_ account: UsageAccount, now: Date, slots: [UsageMetric] = UsageMetric.defaultSlots,
                                       calendar: Calendar = .current, locale: Locale = .current,
                                       timeZone: TimeZone = .current) -> String {
        let identity = [account.providerName, planTitle(account.plan)].compactMap { $0 }.joined(separator: " ")
        var parts = [account.label, identity]
        if account.failed {
            parts.append(account.state == .tokenRejected
                         ? String(localized: "Sign-in expired") : String(localized: "Couldn't load usage"))
            parts.append(String(localized: "Renew in Settings"))
        } else {
            for metric in slots {
                let name = metric.title
                let limit = metric.limit(for: account)
                guard let data = metric.value(for: account) else {
                    parts.append(String(localized: "\(name) not reported for this plan"))
                    continue
                }
                let value = data.percent
                let reset = data.resetsAt
                let text = shortResetText(value: value, reset: reset, now: now,
                                          calendar: calendar, locale: locale, timeZone: timeZone)
                var detail = String(localized: "\(name) \(Int(value.rounded()))%")
                if let reset, !text.isEmpty {
                    detail += reset.timeIntervalSince(now) < 86400
                        ? String(localized: ", resets in \(text)") : String(localized: ", resets \(text)")
                } else {
                    detail += value == 0 ? String(localized: ", not started") : String(localized: ", reset time unavailable")
                }
                if limit?.status == "rejected" { detail += String(localized: ", limit reached") }
                parts.append(detail)
            }
            if account.state == .stale {
                parts.append(String(localized: "Stale"))
                parts.append(updated(since: timestamp(account), now: now))
            }
        }
        return parts.joined(separator: " · ")
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

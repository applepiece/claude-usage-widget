import Foundation

// Formatters are reused and confined to the main actor along with their callers.
@MainActor
public enum UsageFormatting {
    public static let iso = ISO8601DateFormatter()
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE"
        return formatter
    }()
    public static let resetDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// The lock confines both cached, non-Sendable formatters, including concurrent metric lookups.
private final class ISODateParser: @unchecked Sendable {
    static let shared = ISODateParser()
    private let lock = NSLock()
    private let whole = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func date(from value: String) -> Date? {
        lock.withLock {
            if let date = fractional.date(from: value) { return date }
            if let date = whole.date(from: value) { return date }
            // Older Foundation versions reject microseconds; retain the reset rather than lose it.
            if let dot = value.firstIndex(of: ".") {
                let tail = value[dot...].drop(while: { $0 == "." || $0.isNumber })
                return whole.date(from: String(value[..<dot]) + String(tail))
            }
            return nil
        }
    }
}

public func parseISO(_ value: String) -> Date? {
    ISODateParser.shared.date(from: value)
}

@MainActor
public func fmtWhen(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                    timeZone: TimeZone = .current) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone
    UsageFormatting.clock.calendar = calendar
    UsageFormatting.clock.timeZone = timeZone
    UsageFormatting.weekday.calendar = calendar
    UsageFormatting.weekday.timeZone = timeZone
    let time = UsageFormatting.clock.string(from: date)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow) { return "TMRW " + time }
    return UsageFormatting.weekday.string(from: date).uppercased() + " " + time
}

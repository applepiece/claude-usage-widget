import Foundation

// Formatters are reused and confined to the main actor along with their callers.
@MainActor
public enum UsageFormatting {
    public static let iso = ISO8601DateFormatter()
    static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
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

@MainActor
public func parseISO(_ value: String) -> Date? {
    if let date = UsageFormatting.fractionalISO.date(from: value) { return date }
    if let date = UsageFormatting.iso.date(from: value) { return date }
    if let dot = value.firstIndex(of: ".") {
        let tail = value[dot...].drop(while: { $0 == "." || $0.isNumber })
        return UsageFormatting.iso.date(from: String(value[..<dot]) + String(tail))
    }
    return nil
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

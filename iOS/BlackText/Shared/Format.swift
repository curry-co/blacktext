import Foundation

// TODO(core): move to BlackTextCore. A copy of `Format` from the Mac app's EditorController.swift.

enum Format {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let dayYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func number(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func words(_ count: Int) -> String {
        "\(number(count)) \(count == 1 ? "word" : "words")"
    }

    /// "2:14 PM" today, "Monday" this week, "Apr 12" this year, "Apr 12, 2024" before.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) { return timeFormatter.string(from: date) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return weekdayFormatter.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return dayFormatter.string(from: date) }
        return dayYearFormatter.string(from: date)
    }

    /// Version rows: "2:14 PM" today, otherwise like `dateTime`.
    static func versionTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dateTime(date)
    }

    /// "Today, 2:14 PM", "Apr 12, 4:20 PM", "Apr 12, 2024, 4:20 PM".
    static func dateTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(dayFormatter.string(from: date)), \(time)"
        }
        return "\(dayYearFormatter.string(from: date)), \(time)"
    }
}

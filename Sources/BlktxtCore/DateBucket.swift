import Foundation

/// The quiet date headers in the sidebar: Today, Yesterday, Previous 7 Days, Previous 30 Days,
/// then months of this year, then years.
public enum DateBucket: Hashable, Sendable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case month(Int, Int)
    case year(Int)

    public init(_ date: Date, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today)! }
        let year = calendar.component(.year, from: date)
        if date >= today {
            self = .today
        } else if date >= daysAgo(1) {
            self = .yesterday
        } else if date >= daysAgo(7) {
            self = .previous7Days
        } else if date >= daysAgo(30) {
            self = .previous30Days
        } else if year == calendar.component(.year, from: now) {
            self = .month(year, calendar.component(.month, from: date))
        } else {
            self = .year(year)
        }
    }

    public func title(calendar: Calendar = .current) -> String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case let .month(_, month): return calendar.standaloneMonthSymbols[month - 1]
        case let .year(year): return String(year)
        }
    }
}

import Foundation

public enum CivilEra: String, Codable, Sendable { case ce, bce }

public enum AtlasDateError: Error, Equatable {
    case invalidYear
    case invalidMonth
    case invalidDay
}

public enum TimelineGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case day, month, year, decade, century, millennium
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var stepYears: Double {
        switch self {
        case .day: 1 / 365.2425
        case .month: 1 / 12
        case .year: 1
        case .decade: 10
        case .century: 100
        case .millennium: 1_000
        }
    }
    /// Useful default viewport span; actual civil day/month navigation uses AtlasDate.
    public var windowYears: Double { stepYears * 20 }
    public static func suggested(forSpan span: Double) -> Self {
        switch abs(span) {
        case ..<0.15: .day
        case ..<2: .month
        case ..<30: .year
        case ..<300: .decade
        case ..<3_000: .century
        default: .millennium
        }
    }
}

public struct TimelineWindow: Codable, Hashable, Sendable {
    public var lowerBound: Double
    public var upperBound: Double
    public init(lowerBound: Double, upperBound: Double) {
        self.lowerBound = min(lowerBound, upperBound)
        self.upperBound = max(lowerBound, upperBound)
    }
    public init(center: Double, span: Double) {
        self.init(lowerBound: center - abs(span) / 2, upperBound: center + abs(span) / 2)
    }
    public var center: Double { lowerBound + (upperBound - lowerBound) / 2 }
    public var span: Double { upperBound - lowerBound }
    public func contains(_ year: Double) -> Bool { year >= lowerBound && year <= upperBound }
    public func overlaps(start: Double, end: Double) -> Bool {
        start.isFinite && end.isFinite && min(start, end) <= upperBound && max(start, end) >= lowerBound
    }
    public func overlaps(event: AtlasEvent) -> Bool { overlaps(start: event.start, end: event.end) }
}

/// Uses the proleptic Gregorian calendar and astronomical years, preserving BCE without inventing a civil year zero.
public enum AtlasDate {
    public struct CivilDate: Equatable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
        public let era: CivilEra
        public init(year: Int, month: Int, day: Int, era: CivilEra) {
            self.year = year; self.month = month; self.day = day; self.era = era
        }
    }
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    public static func astronomicalYear(civilYear: Int, era: CivilEra) throws -> Int {
        guard civilYear > 0 else { throw AtlasDateError.invalidYear }
        return era == .bce ? 1 - civilYear : civilYear
    }
    public static func isLeapYear(_ astronomicalYear: Int) -> Bool {
        astronomicalYear.isMultiple(of: 4) && (!astronomicalYear.isMultiple(of: 100) || astronomicalYear.isMultiple(of: 400))
    }
    public static func daysInMonth(_ month: Int, astronomicalYear: Int) -> Int {
        guard (1...12).contains(month) else { return 0 }
        if month == 2 { return isLeapYear(astronomicalYear) ? 29 : 28 }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }
    public static func civilDate(year: Int, month: Int = 1, day: Int = 1, era: CivilEra = .ce) throws -> Double {
        let astronomical = try astronomicalYear(civilYear: year, era: era)
        guard (1...12).contains(month) else { throw AtlasDateError.invalidMonth }
        guard (1...daysInMonth(month, astronomicalYear: astronomical)).contains(day) else { throw AtlasDateError.invalidDay }
        let previousDays = (1..<month).reduce(0) { $0 + daysInMonth($1, astronomicalYear: astronomical) }
        return Double(astronomical) + Double(previousDays + day - 1) / Double(isLeapYear(astronomical) ? 366 : 365)
    }
    public static func components(_ decimalYear: Double) -> CivilDate? {
        // Bound Int conversion and malformed JSON dates; no Foundation Date range limits.
        guard decimalYear.isFinite, abs(decimalYear) < 100_000_000_000_000 else { return nil }
        let astronomical = Int(floor(decimalYear))
        let days = isLeapYear(astronomical) ? 366 : 365
        var dayIndex = min(days - 1, max(0, Int(floor((decimalYear - Double(astronomical)) * Double(days) + 0.000_1))))
        var month = 1
        while dayIndex >= daysInMonth(month, astronomicalYear: astronomical), month < 12 {
            dayIndex -= daysInMonth(month, astronomicalYear: astronomical)
            month += 1
        }
        return CivilDate(year: astronomical <= 0 ? 1 - astronomical : astronomical,
                         month: month, day: dayIndex + 1, era: astronomical <= 0 ? .bce : .ce)
    }
    public static func formatted(_ decimalYear: Double, precision: String = "year") -> String {
        guard let value = components(decimalYear) else { return "Unknown date" }
        let year = value.era == .bce ? "\(value.year) BCE" : "\(value.year) CE"
        switch precision.lowercased() {
        case "day": return "\(value.day) \(monthNames[value.month - 1]) \(year)"
        case "month": return "\(monthNames[value.month - 1]) \(year)"
        default: return year
        }
    }

    public static func advancing(_ decimalYear: Double, by amount: Int, granularity: TimelineGranularity) -> Double {
        guard let value = components(decimalYear), amount > -100_000_000, amount < 100_000_000 else { return decimalYear }
        let astronomical = value.era == .bce ? 1 - value.year : value.year
        if granularity == .day {
            var y = astronomical, m = value.month, d = value.day + amount
            while d > daysInMonth(m, astronomicalYear: y) {
                d -= daysInMonth(m, astronomicalYear: y); m += 1
                if m == 13 { m = 1; y += 1 }
            }
            while d < 1 {
                m -= 1
                if m == 0 { m = 12; y -= 1 }
                d += daysInMonth(m, astronomicalYear: y)
            }
            return decimal(y: y, month: m, day: d)
        }
        if granularity == .month {
            let total = astronomical * 12 + value.month - 1 + amount
            let y = Int(floor(Double(total) / 12))
            let m = total - y * 12 + 1
            return decimal(y: y, month: m, day: min(value.day, daysInMonth(m, astronomicalYear: y)))
        }
        let y = astronomical + amount * Int(granularity.stepYears)
        return decimal(y: y, month: value.month, day: min(value.day, daysInMonth(value.month, astronomicalYear: y)))
    }
    private static func decimal(y: Int, month: Int, day: Int) -> Double {
        // Inputs here were checked by components/advancing.
        let era: CivilEra = y <= 0 ? .bce : .ce
        return (try? civilDate(year: y <= 0 ? 1 - y : y, month: month, day: day, era: era)) ?? Double(y)
    }
}

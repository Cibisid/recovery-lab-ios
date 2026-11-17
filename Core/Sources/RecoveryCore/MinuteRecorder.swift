import Foundation

/// Running totals for one minute of the day.
public struct MinuteBucket: Codable, Equatable {
    public var hrSum: Double = 0
    public var hrCount: Int = 0
    public var rrCount: Int = 0
    /// Sum of squared differences between successive accepted RR intervals (ms squared).
    public var sqDiffSum: Double = 0
    public var diffCount: Int = 0

    public init() {}
}

/// Turns a stream of heart-rate samples into per-minute rows, the same format the
/// Recovery Lab web page stores: [minuteOfDay, averageHr, rrCount, sumSquaredDiffs, diffCount].
public final class MinuteRecorder {
    /// day ("yyyy-MM-dd") -> minute of day (0...1439) -> bucket
    public private(set) var days: [String: [Int: MinuteBucket]] = [:]
    private var lastRR: Double?
    /// Recent squared RR differences, for a live HRV readout.
    public private(set) var recentSquares: [Double] = []

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Adds one sample. Returns the day key and minute it landed in.
    @discardableResult
    public func add(_ sample: HeartRateSample, at date: Date, calendar: Calendar = .current) -> (day: String, minute: Int) {
        let day = MinuteRecorder.dayKey(date, calendar: calendar)
        let minute = MinuteRecorder.minuteOfDay(date, calendar: calendar)
        var bucket = days[day]?[minute] ?? MinuteBucket()

        if sample.bpm > 25 && sample.bpm < 230 {
            bucket.hrSum += Double(sample.bpm)
            bucket.hrCount += 1
        }
        for rr in sample.rrMs {
            // Outside a plausible beat interval: drop it and break the chain.
            if rr < 300 || rr > 2000 {
                lastRR = nil
                continue
            }
            if let last = lastRR {
                let diff = rr - last
                // Reject jumps that are almost certainly missed or extra beats.
                if abs(diff) < 200 && abs(diff) / last < 0.2 {
                    bucket.sqDiffSum += diff * diff
                    bucket.diffCount += 1
                    recentSquares.append(diff * diff)
                    if recentSquares.count > 80 { recentSquares.removeFirst() }
                }
            }
            bucket.rrCount += 1
            lastRR = rr
        }

        var dayBuckets = days[day] ?? [:]
        dayBuckets[minute] = bucket
        days[day] = dayBuckets
        return (day, minute)
    }

    /// Live RMSSD in milliseconds from the most recent beats, or nil if there are too few.
    public var liveHrv: Int? {
        guard recentSquares.count > 20 else { return nil }
        let mean = recentSquares.reduce(0, +) / Double(recentSquares.count)
        return Int(mean.squareRoot().rounded())
    }

    public func load(day: String, buckets: [Int: MinuteBucket]) {
        days[day] = buckets
    }

    public func buckets(for day: String) -> [Int: MinuteBucket] {
        days[day] ?? [:]
    }

    public func drop(day: String) {
        days[day] = nil
    }

    /// Number of minutes of the given day that have a heart-rate reading.
    public func minutesWithHeartRate(_ day: String) -> Int {
        (days[day] ?? [:]).values.filter { $0.hrCount > 0 }.count
    }

    /// The rows for one day as a JSON array string, sorted by minute.
    public func rowsJSON(for day: String) -> String {
        let buckets = days[day] ?? [:]
        let parts: [String] = buckets.keys.sorted().compactMap { minute in
            guard let b = buckets[minute], b.hrCount > 0 || b.rrCount > 0 else { return nil }
            let hr: String
            if b.hrCount > 0 {
                let avg = (b.hrSum / Double(b.hrCount) * 10).rounded() / 10
                hr = MinuteRecorder.number(avg)
            } else {
                hr = "null"
            }
            return "[\(minute),\(hr),\(b.rrCount),\(Int(b.sqDiffSum.rounded())),\(b.diffCount)]"
        }
        return "[" + parts.joined(separator: ",") + "]"
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

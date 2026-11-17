import XCTest
@testable import RecoveryCore

final class RecoveryCoreTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testParsesEightBitHeartRateWithoutRR() {
        let s = HeartRateParser.parse(Data([0x00, 61]))
        XCTAssertEqual(s, HeartRateSample(bpm: 61, rrMs: []))
    }

    func testParsesSixteenBitHeartRate() {
        let s = HeartRateParser.parse(Data([0x01, 0x2C, 0x01]))
        XCTAssertEqual(s?.bpm, 300)
    }

    func testParsesRRIntervals() {
        // flags 0x10 = RR present; 1024/1024 s = 1000 ms, 512/1024 s = 500 ms
        let s = HeartRateParser.parse(Data([0x10, 60, 0x00, 0x04, 0x00, 0x02]))
        XCTAssertEqual(s?.bpm, 60)
        XCTAssertEqual(s?.rrMs ?? [], [1000, 500])
    }

    func testSkipsEnergyExpendedField() {
        // flags 0x18 = energy expended + RR present
        let s = HeartRateParser.parse(Data([0x18, 70, 0xAA, 0xBB, 0x00, 0x04]))
        XCTAssertEqual(s?.rrMs ?? [], [1000])
    }

    func testRejectsShortPackets() {
        XCTAssertNil(HeartRateParser.parse(Data([0x00])))
        XCTAssertNil(HeartRateParser.parse(Data([0x01, 0x40])))
    }

    func testAggregatesIntoMinuteRows() {
        let r = MinuteRecorder()
        // 2026-11-17 10:19:00 UTC
        let base = Date(timeIntervalSince1970: 1_794_910_740)
        r.add(HeartRateSample(bpm: 60, rrMs: [1000, 1010]), at: base, calendar: utc)
        r.add(HeartRateSample(bpm: 62, rrMs: [990]), at: base.addingTimeInterval(20), calendar: utc)
        r.add(HeartRateSample(bpm: 70, rrMs: []), at: base.addingTimeInterval(60), calendar: utc)
        // diffs: 1010-1000 = 10, 990-1010 = -20 -> squares 100 + 400
        XCTAssertEqual(r.rowsJSON(for: "2026-11-17"), "[[619,61,3,500,2],[620,70,0,0,0]]")
        XCTAssertEqual(r.minutesWithHeartRate("2026-11-17"), 2)
    }

    func testRejectsImplausibleRRJumps() {
        let r = MinuteRecorder()
        let t = Date(timeIntervalSince1970: 1_794_910_740)
        // 1000 -> 1500 is a 50% jump (missed beat): no diff counted. 250 is out of range: chain breaks.
        r.add(HeartRateSample(bpm: 60, rrMs: [1000, 1500, 250, 1000, 1005]), at: t, calendar: utc)
        let b = r.buckets(for: "2026-11-17")[619]
        XCTAssertEqual(b?.rrCount, 4)
        XCTAssertEqual(b?.diffCount, 1)
        XCTAssertEqual(b?.sqDiffSum ?? 0, 25, accuracy: 0.001)
    }

    func testIgnoresImplausibleHeartRates() {
        let r = MinuteRecorder()
        let t = Date(timeIntervalSince1970: 1_794_910_740)
        r.add(HeartRateSample(bpm: 0, rrMs: []), at: t, calendar: utc)
        r.add(HeartRateSample(bpm: 255, rrMs: []), at: t, calendar: utc)
        XCTAssertEqual(r.rowsJSON(for: "2026-11-17"), "[]")
    }

    func testAverageKeepsOneDecimal() {
        let r = MinuteRecorder()
        let t = Date(timeIntervalSince1970: 1_794_910_740)
        r.add(HeartRateSample(bpm: 60, rrMs: []), at: t, calendar: utc)
        r.add(HeartRateSample(bpm: 61, rrMs: []), at: t, calendar: utc)
        r.add(HeartRateSample(bpm: 61, rrMs: []), at: t, calendar: utc)
        XCTAssertEqual(r.rowsJSON(for: "2026-11-17"), "[[619,60.7,0,0,0]]")
    }
}

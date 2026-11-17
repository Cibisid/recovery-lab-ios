import Foundation

/// One notification from the standard Bluetooth Heart Rate Measurement characteristic (0x2A37).
public struct HeartRateSample: Equatable {
    public let bpm: Int
    /// Beat-to-beat (RR) intervals in milliseconds, in the order the band sent them.
    public let rrMs: [Double]

    public init(bpm: Int, rrMs: [Double]) {
        self.bpm = bpm
        self.rrMs = rrMs
    }
}

public enum HeartRateParser {
    /// Parses the Heart Rate Measurement value defined by the Bluetooth Heart Rate Service.
    /// Byte 0 is a flags field: bit 0 = 16-bit heart rate, bit 3 = energy expended present,
    /// bit 4 = RR intervals present (units of 1/1024 s).
    public static func parse(_ data: Data) -> HeartRateSample? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        var index = 1
        let bpm: Int
        if flags & 0x01 != 0 {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
            index = 3
        } else {
            bpm = Int(bytes[1])
            index = 2
        }
        if flags & 0x08 != 0 { index += 2 }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while index + 1 < bytes.count {
                let raw = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
                rr.append(Double(raw) / 1024.0 * 1000.0)
                index += 2
            }
        }
        return HeartRateSample(bpm: bpm, rrMs: rr)
    }
}

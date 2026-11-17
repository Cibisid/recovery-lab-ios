import Foundation
#if canImport(RecoveryCore)
import RecoveryCore
#endif

/// Keeps the per-minute recordings on disk and tracks which days still need uploading.
/// All access happens on the main thread.
final class MinuteStore {
    static let shared = MinuteStore()

    private let recorder = MinuteRecorder()
    private let folder: URL
    private var lastSlot = ""
    /// Bumped whenever a day's data changes; compared with `uploadedRevision` to know what is pending.
    private var revision: [String: Int] = [:]
    private var uploadedRevision: [String: Int] = [:]
    private let pendingKey = "pendingDays"

    var deviceName = ""
    var battery: Int?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("minutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Files stay readable while the phone is locked (after the first unlock since boot).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: folder.path)

        let today = MinuteRecorder.dayKey(Date(), calendar: .current)
        let yesterday = MinuteRecorder.dayKey(Date().addingTimeInterval(-86_400), calendar: .current)
        for day in [yesterday, today] { loadFromDisk(day) }
        for day in UserDefaults.standard.stringArray(forKey: pendingKey) ?? [] {
            loadFromDisk(day)
            revision[day] = 1
        }
    }

    private func fileURL(_ day: String) -> URL {
        folder.appendingPathComponent("\(day).buckets.json")
    }

    private func loadFromDisk(_ day: String) {
        guard recorder.buckets(for: day).isEmpty,
              let data = try? Data(contentsOf: fileURL(day)),
              let buckets = try? JSONDecoder().decode([Int: MinuteBucket].self, from: data) else { return }
        recorder.load(day: day, buckets: buckets)
    }

    private func saveToDisk(_ day: String) {
        guard let data = try? JSONEncoder().encode(recorder.buckets(for: day)) else { return }
        try? data.write(to: fileURL(day), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func savePending() {
        UserDefaults.standard.set(pendingDays(), forKey: pendingKey)
    }

    /// Records one sample. Returns true when a new minute started (a good moment to save and upload).
    @discardableResult
    func add(_ sample: HeartRateSample, at date: Date = Date()) -> Bool {
        let (day, minute) = recorder.add(sample, at: date)
        revision[day, default: 0] += 1
        let slot = "\(day)#\(minute)"
        guard slot != lastSlot else { return false }
        let previousDay = lastSlot.components(separatedBy: "#").first ?? ""
        lastSlot = slot
        if !previousDay.isEmpty && previousDay != day { saveToDisk(previousDay) }
        saveToDisk(day)
        savePending()
        return true
    }

    func flush() {
        let day = MinuteRecorder.dayKey(Date(), calendar: .current)
        saveToDisk(day)
        savePending()
    }

    var liveHrv: Int? { recorder.liveHrv }

    func minutesToday() -> Int {
        recorder.minutesWithHeartRate(MinuteRecorder.dayKey(Date(), calendar: .current))
    }

    /// Days whose latest data has not been uploaded yet, oldest first.
    func pendingDays() -> [String] {
        revision.keys.filter { revision[$0, default: 0] > uploadedRevision[$0, default: 0] }.sorted()
    }

    func currentRevision(_ day: String) -> Int { revision[day, default: 0] }

    func markUploaded(_ day: String, revision uploaded: Int) {
        uploadedRevision[day] = uploaded
        savePending()
    }

    /// The JSON file uploaded for one day.
    func uploadBody(_ day: String) -> Data {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let name = deviceName.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let batteryText = battery.map(String.init) ?? "null"
        let json = "{\"date\":\"\(day)\",\"tz\":\"\(TimeZone.current.identifier)\",\"device\":\"\(name)\","
            + "\"battery\":\(batteryText),\"updated\":\"\(stamp)\",\"rows\":\(recorder.rowsJSON(for: day))}\n"
        return Data(json.utf8)
    }
}

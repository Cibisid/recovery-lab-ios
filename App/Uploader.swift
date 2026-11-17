import Foundation
import UIKit

/// Sends each day's minute file to a private GitHub repository through the Contents API.
final class Uploader: ObservableObject {
    static let shared = Uploader()

    @Published var lastUpload: Date?
    @Published var lastError: String?
    @Published var hasToken = Keychain.readToken() != nil

    private let store = MinuteStore.shared
    private var running = false
    private var lastAttempt = Date.distantPast
    private let interval: TimeInterval = 600
    private var shaCache: [String: String]
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    var repo: String {
        get { UserDefaults.standard.string(forKey: "repo") ?? "Cibisid/recovery-lab-data" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "repo") }
    }

    private init() {
        shaCache = (UserDefaults.standard.dictionary(forKey: "shaCache") as? [String: String]) ?? [:]
        if let t = UserDefaults.standard.object(forKey: "lastUpload") as? Date { lastUpload = t }
    }

    func saveToken(_ token: String) {
        Keychain.saveToken(token)
        hasToken = Keychain.readToken() != nil
    }

    /// Uploads pending days if enough time has passed since the last attempt.
    func uploadIfDue(force: Bool = false) {
        guard !running else { return }
        guard force || Date().timeIntervalSince(lastAttempt) >= interval else { return }
        guard let token = Keychain.readToken() else {
            lastError = "Add your GitHub token in Settings to start uploading."
            return
        }
        let days = store.pendingDays()
        guard !days.isEmpty else { return }
        running = true
        lastAttempt = Date()

        // Ask iOS for a little extra time so the upload can finish in the background.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "upload") { [weak self] in
            self?.endBackgroundTask()
        }

        Task { @MainActor in
            var failure: String?
            for day in days {
                let revision = store.currentRevision(day)
                do {
                    try await put(day: day, body: store.uploadBody(day), token: token)
                    store.markUploaded(day, revision: revision)
                } catch {
                    failure = (error as? UploadError)?.message ?? error.localizedDescription
                    break
                }
            }
            if let failure {
                lastError = failure
            } else {
                lastError = nil
                lastUpload = Date()
                UserDefaults.standard.set(lastUpload, forKey: "lastUpload")
            }
            running = false
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private struct UploadError: Error { let message: String }

    private func request(_ method: String, path: String, token: String) -> URLRequest? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 25
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("RecoveryLab-iOS", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func currentSha(path: String, token: String) async throws -> String? {
        guard let r = request("GET", path: path, token: token) else { throw UploadError(message: "The repository name looks wrong.") }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UploadError(message: explain(code))
        }
        return object["sha"] as? String
    }

    private func put(day: String, body: Data, token: String) async throws {
        let path = "minutes/\(day).json"
        for attempt in 0..<2 {
            guard var r = request("PUT", path: path, token: token) else { throw UploadError(message: "The repository name looks wrong.") }
            var payload: [String: Any] = [
                "message": "minutes \(day)",
                "content": body.base64EncodedString()
            ]
            if let sha = shaCache[day] { payload["sha"] = sha }
            r.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 201 {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let content = object["content"] as? [String: Any],
                   let sha = content["sha"] as? String {
                    shaCache[day] = sha
                    // Keep the cache small: only recent days are ever uploaded again.
                    if shaCache.count > 10 {
                        for key in shaCache.keys.sorted().dropLast(10) { shaCache[key] = nil }
                    }
                    UserDefaults.standard.set(shaCache, forKey: "shaCache")
                }
                return
            }
            // 409/422 mean our idea of the file's version is stale (or missing): look it up and retry once.
            if (code == 409 || code == 422) && attempt == 0 {
                shaCache[day] = try await currentSha(path: path, token: token)
                continue
            }
            throw UploadError(message: explain(code))
        }
    }

    private func explain(_ code: Int) -> String {
        switch code {
        case 401: return "GitHub rejected the token. Create a new one and paste it in Settings."
        case 403: return "The token can't write to \(repo). Give it Contents: Read and write on that repository."
        case 404: return "Repository \(repo) wasn't found, or the token can't see it."
        case 0: return "No internet connection. It will retry."
        default: return "GitHub answered with error \(code). It will retry."
        }
    }
}

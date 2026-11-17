import Foundation
import AppKit

struct UpdateInfo: Codable {
    let version: String
    let codename: String
    let url: URL
}

/// Проверка новых релизов на GitHub и скачивание DMG.
final class UpdateService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateService()

    @Published private(set) var updateInfo: UpdateInfo?
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var updateProgressText = ""
    @Published private(set) var downloadProgress: Double = 0

    private var downloadTask: URLSessionDownloadTask?
    private let releasesURL = URL(string: "https://api.github.com/repos/Nuteres/Golosok/releases/latest")!
    private let checkInterval: TimeInterval = 4 * 3600

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        if let lastActive = defaults.string(forKey: "lastActiveVersion"), lastActive != currentVersion {
            defaults.removeObject(forKey: "cachedUpdateInfo")
            defaults.removeObject(forKey: "updateCheckETag")
            defaults.removeObject(forKey: "lastUpdateCheckAt")
        }
        defaults.set(currentVersion, forKey: "lastActiveVersion")
    }

    func checkUpdates(force: Bool = false) {
        let defaults = UserDefaults.standard
        let currentVer = currentVersion
        let lastCheck = defaults.object(forKey: "lastUpdateCheckAt") as? Date

        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < checkInterval {
            if let data = defaults.data(forKey: "cachedUpdateInfo") {
                if let cached = try? JSONDecoder().decode(UpdateInfo.self, from: data),
                   Self.compareVersions(cached.version, currentVer) == .orderedDescending {
                    DispatchQueue.main.async { self.updateInfo = cached }
                } else {
                    defaults.removeObject(forKey: "cachedUpdateInfo")
                    DispatchQueue.main.async { self.updateInfo = nil }
                }
            }
            return
        }

        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag = defaults.string(forKey: "updateCheckETag") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 {
                defaults.set(Date(), forKey: "lastUpdateCheckAt")
                return
            }
            if let etag = http?.value(forHTTPHeaderField: "Etag") {
                defaults.set(etag, forKey: "updateCheckETag")
            }
            defer { defaults.set(Date(), forKey: "lastUpdateCheckAt") }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String, let releaseName = json["name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let dmgAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let downloadString = dmgAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadString) else { return }

            let result: UpdateInfo?
            if Self.compareVersions(tagName, currentVer) == .orderedDescending {
                let codename = releaseName.components(separatedBy: " ").last ?? "UPDATE"
                result = UpdateInfo(version: tagName, codename: codename.uppercased(), url: downloadURL)
            } else {
                result = nil
                defaults.removeObject(forKey: "updateCheckETag")
            }
            if let result, let encoded = try? JSONEncoder().encode(result) {
                defaults.set(encoded, forKey: "cachedUpdateInfo")
            } else {
                defaults.removeObject(forKey: "cachedUpdateInfo")
            }
            DispatchQueue.main.async { self.updateInfo = result }
        }.resume()
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let ta = a.replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }
        let tb = b.replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(ta.count, tb.count) {
            let av = i < ta.count ? ta[i] : 0
            let bv = i < tb.count ? tb[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    func cancelUpdateDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        DispatchQueue.main.async {
            self.isDownloadingUpdate = false
            self.updateProgressText = ""
            self.downloadProgress = 0
        }
    }

    func downloadAndInstallUpdate() {
        guard let updateURL = updateInfo?.url else { return }
        isDownloadingUpdate = true
        updateProgressText = String(localized: "Подключение...")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: updateURL)
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let text = String(
            format: "%.0f / %.0f МБ (%d%%)",
            Double(totalBytesWritten) / 1_048_576,
            Double(totalBytesExpectedToWrite) / 1_048_576,
            Int(progress * 100)
        )
        DispatchQueue.main.async {
            self.downloadProgress = progress
            self.updateProgressText = text
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Golosok_Update.dmg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                self.isDownloadingUpdate = false
                self.updateProgressText = String(localized: "Открытие...")
                NSWorkspace.shared.open(dest)
            }
        } catch {
            DispatchQueue.main.async {
                self.isDownloadingUpdate = false
                self.updateProgressText = String(localized: "Ошибка")
            }
        }
        session.finishTasksAndInvalidate()
    }
}

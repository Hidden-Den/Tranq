import Foundation

struct UpdateInfo: Codable, Equatable {
    let version: String
    /// Страница релиза на GitHub: оттуда скачивается DMG.
    let url: URL
}

/// Проверка новых релизов на GitHub. Скачивание и установка идут по ссылке на страницу релиза.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var updateInfo: UpdateInfo?

    static let releasesAPIURL = URL(string: "https://api.github.com/repos/Hidden-Den/Tranq/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/Hidden-Den/Tranq/releases")!
    private let checkInterval: TimeInterval = 4 * 3600

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private init() {
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

        var request = URLRequest(url: Self.releasesAPIURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
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
            guard let data else { return }

            let result = Self.parseRelease(data, currentVersion: currentVer)
            if let result, let encoded = try? JSONEncoder().encode(result) {
                defaults.set(encoded, forKey: "cachedUpdateInfo")
            } else {
                defaults.removeObject(forKey: "cachedUpdateInfo")
                defaults.removeObject(forKey: "updateCheckETag")
            }
            DispatchQueue.main.async { self.updateInfo = result }
        }.resume()
    }

    /// Ответ GitHub о последнем релизе: данные об обновлении, если версия новее текущей.
    static func parseRelease(_ data: Data, currentVersion: String) -> UpdateInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              compareVersions(tag, currentVersion) == .orderedDescending else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return UpdateInfo(version: tag, url: page)
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
}

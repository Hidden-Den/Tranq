import Foundation

/// Где приложение хранит данные и настройки.
///
/// Unit-тесты запускаются внутри самого приложения. Чтобы они не стирали заметки,
/// словарь, кэш ИИ и настройки пользователя, под тестами данные и настройки
/// перенаправляются во временную папку и отдельный домен UserDefaults.
/// Модели только читаются и остаются на обычном месте.
enum AppEnvironment {
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Имя папки данных в Application Support, единое для всех хранилищ.
    static let dataFolderName = "Tranq"

    private static let testDefaultsSuite = "nuter.Tranq.tests"

    /// Папка данных: ~/Library/Application Support/Tranq или временная под тестами.
    static let dataDirectory: URL = {
        let fm = FileManager.default
        let dir: URL
        if isRunningTests {
            dir = fm.temporaryDirectory.appendingPathComponent("tranq-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? fm.removeItem(at: dir)
        } else {
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            dir = appSupport.appendingPathComponent(dataFolderName, isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Настройки приложения; под тестами — чистый отдельный домен.
    static let defaults: UserDefaults = {
        guard isRunningTests, let suite = UserDefaults(suiteName: testDefaultsSuite) else { return .standard }
        suite.removePersistentDomain(forName: testDefaultsSuite)
        return suite
    }()
}

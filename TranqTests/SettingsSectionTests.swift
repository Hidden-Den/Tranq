import Testing
import Foundation
@testable import Tranq

struct SettingsSectionTests {
    private func scratch() -> UserDefaults {
        let d = UserDefaults(suiteName: "tranq-settings-section-\(UUID().uuidString)")!
        return d
    }

    @Test func sectionOrder() {
        #expect(SettingsSection.allCases == [.dictation, .recognition, .processing, .provider, .app, .data])
    }

    @Test func storedSectionRoundTrips() {
        let d = scratch()
        SettingsSection.provider.store(in: d)
        #expect(SettingsSection.restore(from: d) == .provider)
    }

    /// Review Focus 3: неизвестное или пустое значение открывает первый раздел.
    @Test func unknownStoredSectionFallsBackToDictation() {
        let d = scratch()
        d.set("какой-то-будущий-раздел", forKey: "settings.section")
        #expect(SettingsSection.restore(from: d) == .dictation)
        let empty = scratch()
        #expect(SettingsSection.restore(from: empty) == .dictation)
    }

    @Test func everySectionHasTitle() {
        for s in SettingsSection.allCases { #expect(!s.title.isEmpty) }
    }

    /// Тот же путь, которым пользуется боковое меню: сырая строка из `@AppStorage`.
    @Test func fromRawFallsBackToDictationForNilEmptyAndUnknown() {
        #expect(SettingsSection.from(raw: nil) == .dictation)
        #expect(SettingsSection.from(raw: "") == .dictation)
        #expect(SettingsSection.from(raw: "какой-то-будущий-раздел") == .dictation)
    }

    @Test func fromRawRoundTripsEveryValidValue() {
        for s in SettingsSection.allCases {
            #expect(SettingsSection.from(raw: s.rawValue) == s)
        }
    }
}

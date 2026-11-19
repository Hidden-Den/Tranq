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
}

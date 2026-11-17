//
//  PromptModeSettingsTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

extension SharedSettingsSuites {
    /// Режим промпта выключен по умолчанию и переживает перезапуск.
    struct PromptModeSettingsTests {
        @Test func promptModeIsOffByDefaultAndPersists() {
            let settings = VoiceIntelligenceSettings.shared
            let saved = settings.promptModeEnabled
            defer { settings.promptModeEnabled = saved }

            settings.promptModeEnabled = true
            #expect(AppEnvironment.defaults.bool(forKey: "voice.promptModeEnabled"))
            settings.resetToDefaults()
            #expect(settings.promptModeEnabled == false)
        }
    }
}

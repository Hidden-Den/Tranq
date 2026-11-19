//
//  LockPreferenceTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

struct LockPreferenceTests {
    private func scratch() -> UserDefaults {
        UserDefaults(suiteName: "tranq-lock-pref-\(UUID().uuidString)")!
    }

    /// Значения нет: замок выключен.
    @Test func defaultsToOff() {
        #expect(AppPreferences.historyLockEnabled(in: scratch()) == false)
    }

    @Test func valuePersists() {
        let d = scratch()
        AppPreferences.setHistoryLockEnabled(true, in: d)
        #expect(AppPreferences.historyLockEnabled(in: d) == true)
        #expect(d.object(forKey: "historyLockEnabled") as? Bool == true)
        AppPreferences.setHistoryLockEnabled(false, in: d)
        #expect(AppPreferences.historyLockEnabled(in: d) == false)
    }
}

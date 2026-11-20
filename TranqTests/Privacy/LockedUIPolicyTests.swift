//
//  LockedUIPolicyTests.swift
//  TranqTests
//

import Testing
@testable import Tranq

/// Авто-открытие заметки при запертой истории вкладку не переключает.
struct LockedUIPolicyTests {
    @Test func autoOpenDoesNotSwitchWhileLocked() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: false, lockState: .locked) == false)
    }

    @Test func autoOpenWorksWhenLockOff() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: false, lockState: .off) == true)
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: false, lockState: .unlocked) == true)
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: true, lockState: .off) == false)
    }

    @Test func autoOpenDoesNotSwitchWhenKeyUnavailable() {
        #expect(AutoOpenPolicy.shouldSwitchToHistory(autoOpenEnabled: true, isWindowVisible: false, lockState: .keyUnavailable) == false)
    }

    @Test func historyHiddenOnlyWhenLockedOrKeyUnavailable() {
        #expect(HistoryLockState.locked.hidesHistory)
        #expect(HistoryLockState.keyUnavailable.hidesHistory)
        #expect(!HistoryLockState.off.hidesHistory)
        #expect(!HistoryLockState.unlocked.hidesHistory)
    }
}

//
//  HistoryLockSettingsModelTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

@MainActor
struct HistoryLockSettingsModelTests {
    private struct Boom: Error {}

    /// Счётчики вызовов и общий ответ закрытий.
    private final class Calls {
        var enable = 0, disable = 0, export = 0
        var failure: Error?
    }

    private func make(isOn: Bool, presence: TestPresence = TestPresence(), calls: Calls = Calls()) -> HistoryLockSettingsModel {
        HistoryLockSettingsModel(
            isOn: isOn,
            presence: presence,
            onEnable: { calls.enable += 1; if let e = calls.failure { throw e } },
            onDisable: { calls.disable += 1; if let e = calls.failure { throw e } },
            onExport: { calls.export += 1; if let e = calls.failure { throw e } })
    }

    @Test func toggleOnOpensEnableSheetWithoutChangingState() {
        let calls = Calls()
        let model = make(isOn: false, calls: calls)
        model.requestToggle(to: true)
        #expect(model.sheet == .enable)
        #expect(model.isOn == false)
        #expect(calls.enable == 0)
    }

    @Test func toggleOffOpensDisableSheetWithoutChangingState() {
        let model = make(isOn: true)
        model.requestToggle(to: false)
        #expect(model.sheet == .disable)
        #expect(model.isOn == true)
    }

    @Test func toggleToCurrentValueDoesNothing() {
        let model = make(isOn: true)
        model.requestToggle(to: true)
        #expect(model.sheet == nil)
    }

    @Test func enableSuccessFlipsStateAndClosesSheet() async {
        let calls = Calls()
        let presence = TestPresence()
        let model = make(isOn: false, presence: presence, calls: calls)
        model.requestToggle(to: true)
        await model.confirm()
        #expect(calls.enable == 1)
        #expect(presence.calls == 0)
        #expect(model.isOn == true)
        #expect(model.sheet == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func enableFailureKeepsStateAndShowsError() async {
        let calls = Calls()
        calls.failure = Boom()
        let model = make(isOn: false, calls: calls)
        model.requestToggle(to: true)
        await model.confirm()
        #expect(model.isOn == false)
        #expect(model.errorMessage != nil)
        #expect(model.isWorking == false)
    }

    @Test func disableNeedsPresenceBeforeClosure() async {
        let calls = Calls()
        let presence = TestPresence()
        presence.outcomes = [HistoryKeyError.denied]
        let model = make(isOn: true, presence: presence, calls: calls)
        model.requestToggle(to: false)
        await model.confirm()
        #expect(presence.calls == 1)
        #expect(calls.disable == 0)
        #expect(model.isOn == true)
        #expect(model.errorMessage != nil)
    }

    @Test func disableSuccessFlipsStateAfterPresence() async {
        let calls = Calls()
        let presence = TestPresence()
        let model = make(isOn: true, presence: presence, calls: calls)
        model.requestToggle(to: false)
        await model.confirm()
        #expect(presence.calls == 1)
        #expect(calls.disable == 1)
        #expect(model.isOn == false)
        #expect(model.sheet == nil)
    }

    @Test func disableClosureFailureKeepsOn() async {
        let calls = Calls()
        calls.failure = Boom()
        let model = make(isOn: true, calls: calls)
        model.requestToggle(to: false)
        await model.confirm()
        #expect(model.isOn == true)
        #expect(model.errorMessage != nil)
    }

    @Test func cancelClosesSheetAndClearsError() async {
        let calls = Calls()
        calls.failure = Boom()
        let model = make(isOn: false, calls: calls)
        model.requestToggle(to: true)
        await model.confirm()
        model.cancel()
        #expect(model.sheet == nil)
        #expect(model.errorMessage == nil)
        #expect(model.isOn == false)
        #expect(calls.disable == 0)
    }

    @Test func retryAfterFailureCanSucceed() async {
        let calls = Calls()
        calls.failure = Boom()
        let model = make(isOn: false, calls: calls)
        model.requestToggle(to: true)
        await model.confirm()
        calls.failure = nil
        await model.confirm()
        #expect(model.isOn == true)
        #expect(model.errorMessage == nil)
        #expect(model.sheet == nil)
    }

    @Test func exportOnlyWhenOnAndUnlocked() {
        let on = make(isOn: true)
        #expect(on.canExport(in: .unlocked) == true)
        #expect(on.canExport(in: .locked) == false)
        #expect(on.canExport(in: .keyUnavailable) == false)
        #expect(on.canExport(in: .off) == false)
        let off = make(isOn: false)
        #expect(off.canExport(in: .unlocked) == false)
    }

    @Test func exportRunsClosureAndReportsFailure() async {
        let calls = Calls()
        let model = make(isOn: true, calls: calls)
        await model.export()
        #expect(calls.export == 1)
        #expect(model.errorMessage == nil)
        calls.failure = Boom()
        await model.export()
        #expect(calls.export == 2)
        #expect(model.errorMessage != nil)
        #expect(model.isOn == true)
    }

    @Test func syncFollowsStoredFlag() {
        let model = make(isOn: false)
        model.sync(to: true)
        #expect(model.isOn == true)
    }

    /// Находки уборки при запуске показываются одной строкой в карточке замка.
    @Test func launchNoticeMapsToShortText() {
        #expect(HistoryMigration.LaunchNotice.lockTurnedOff.text == String(localized: "Замок был выключен после сбоя"))
        #expect(HistoryMigration.LaunchNotice.leftoverPlainHistory.text == String(localized: "Осталась открытая копия истории"))
    }
}

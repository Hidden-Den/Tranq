//
//  PromptHotKeyTests.swift
//  TranqTests
//

import Testing
import Foundation
import CoreGraphics
import Carbon
@testable import Tranq

/// Shift вместе с горячей клавишей запускает одну диктовку в режиме промпта.
/// Тесты в расширении набора `HotKeyTriggerTests`: у них общий `NativeHotKeyManager.shared`,
/// и параллельный запуск двух наборов перемешивает его состояние.
extension HotKeyTriggerTests {

    // MARK: - Сочетание для промпта

    @Test func promptVariantForCombination() {
        #expect(HotKeyTrigger.optionSpace.promptVariant == .combination(keyCode: 49, modifiers: UInt32(optionKey | shiftKey)))
        #expect(HotKeyTrigger.combination(keyCode: 49, modifiers: UInt32(optionKey | shiftKey)).promptVariant == nil)
    }

    @Test func promptVariantForShiftKeysIsNil() {
        #expect(HotKeyTrigger.singleModifier(.leftShift).promptVariant == nil)
        #expect(HotKeyTrigger.singleModifier(.rightShift).promptVariant == nil)
        #expect(HotKeyTrigger.none.promptVariant == nil)
        #expect(HotKeyTrigger.fnKey.promptVariant == .fnKey)
        #expect(HotKeyTrigger.rightOptionKey.promptVariant == .rightOptionKey)
    }

    // MARK: - Одиночная клавиша Fn

    private func withFnTrigger(promptMode: Bool, _ body: (NativeHotKeyManager) async throws -> Void) async rethrows {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        let originalPressed = manager.onHotKeyPressed
        let originalReleased = manager.onHotKeyReleased
        let originalProvider = manager.isPromptModeEnabled
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
            manager.onHotKeyPressed = originalPressed
            manager.onHotKeyReleased = originalReleased
            manager.isPromptModeEnabled = originalProvider
            manager.resetModifierState()
        }
        manager.setTrigger(.singleModifier(.fn))
        manager.mode = .toggle
        manager.isPromptModeEnabled = { promptMode }
        try await body(manager)
    }

    private func pressFn(_ manager: NativeHotKeyManager, withShift: Bool) async throws {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        var flags: CGEventFlags = [.maskSecondaryFn, CGEventFlags(rawValue: 0x00800000)]
        if withShift { flags.insert(.maskShift) }
        down.flags = flags
        manager.handleEventTap(type: .flagsChanged, event: down)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test func fnWithShiftRequestsPrompt() async throws {
        try await withFnTrigger(promptMode: true) { manager in
            var received: Bool?
            manager.onHotKeyPressed = { received = $0 }
            try await pressFn(manager, withShift: true)
            #expect(received == true)
        }
    }

    @Test func fnWithShiftWhenDisabledIsPlain() async throws {
        try await withFnTrigger(promptMode: false) { manager in
            var received: Bool?
            manager.onHotKeyPressed = { received = $0 }
            try await pressFn(manager, withShift: true)
            #expect(received == false)
        }
    }

    @Test func fnWithoutShiftIsPlainEvenWhenEnabled() async throws {
        try await withFnTrigger(promptMode: true) { manager in
            var received: Bool?
            manager.onHotKeyPressed = { received = $0 }
            try await pressFn(manager, withShift: false)
            #expect(received == false)
        }
    }

    // MARK: - Сочетание Carbon

    @Test func carbonHotKeyIdsMapToPromptFlag() {
        let manager = NativeHotKeyManager.shared
        let originalPressed = manager.onHotKeyPressed
        let originalReleased = manager.onHotKeyReleased
        defer {
            manager.onHotKeyPressed = originalPressed
            manager.onHotKeyReleased = originalReleased
        }
        var pressed: [Bool] = []
        var releasedCount = 0
        manager.onHotKeyPressed = { pressed.append($0) }
        manager.onHotKeyReleased = { releasedCount += 1 }

        manager.handleCarbonHotKey(id: NativeHotKeyManager.plainHotKeyID, pressed: true)
        manager.handleCarbonHotKey(id: NativeHotKeyManager.promptHotKeyID, pressed: true)
        manager.handleCarbonHotKey(id: NativeHotKeyManager.promptHotKeyID, pressed: false)
        #expect(pressed == [false, true])
        #expect(releasedCount == 1)
    }

    // MARK: - Регистрация второго сочетания

    private static let rareCombo = HotKeyTrigger.combination(keyCode: 3, modifiers: UInt32(controlKey | optionKey | cmdKey))

    private func withPromptProvider(_ enabled: Bool, _ body: (NativeHotKeyManager) -> Void) {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalProvider = manager.isPromptModeEnabled
        defer {
            manager.trigger = originalTrigger
            manager.isPromptModeEnabled = originalProvider
            manager.refreshPromptRegistration()
        }
        manager.isPromptModeEnabled = { enabled }
        body(manager)
    }

    @Test func promptRegistrationFollowsSettingAndTrigger() {
        withPromptProvider(false) { manager in
            manager.trigger = Self.rareCombo
            manager.refreshPromptRegistration()
            #expect(manager.isPromptHotKeyRegistered == false)

            manager.isPromptModeEnabled = { true }
            manager.refreshPromptRegistration()
            #expect(manager.isPromptHotKeyRegistered == true)

            manager.isPromptModeEnabled = { false }
            manager.refreshPromptRegistration()
            #expect(manager.isPromptHotKeyRegistered == false)
        }
    }

    @Test func promptRegistrationSkippedWhenTriggerHasShift() {
        withPromptProvider(true) { manager in
            manager.trigger = .combination(keyCode: 3, modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
            manager.refreshPromptRegistration()
            #expect(manager.isPromptHotKeyRegistered == false)
        }
    }

    @Test func switchingToSingleModifierDropsPromptRegistration() {
        withPromptProvider(true) { manager in
            manager.trigger = Self.rareCombo
            #expect(manager.isPromptHotKeyRegistered == true)
            manager.trigger = .singleModifier(.fn)
            #expect(manager.isPromptHotKeyRegistered == false)
        }
    }
}

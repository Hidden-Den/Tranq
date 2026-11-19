import Testing
import Foundation
import CoreGraphics
@testable import Tranq

@Suite(.serialized)
@MainActor
struct HotKeyTriggerTests {
    @Test func singleModifierKeyCodeMapping() {
        #expect(SingleModifierKey.from(keyCode: 63) == .fn)
        #expect(SingleModifierKey.from(keyCode: 61) == .rightOption)
        #expect(SingleModifierKey.from(keyCode: 58) == .leftOption)
        #expect(SingleModifierKey.from(keyCode: 54) == .rightCommand)
        #expect(SingleModifierKey.from(keyCode: 55) == .leftCommand)
        #expect(SingleModifierKey.from(keyCode: 62) == .rightControl)
        #expect(SingleModifierKey.from(keyCode: 59) == .leftControl)
        #expect(SingleModifierKey.from(keyCode: 60) == .rightShift)
        #expect(SingleModifierKey.from(keyCode: 56) == .leftShift)
        #expect(SingleModifierKey.from(keyCode: 57) == nil)
        #expect(SingleModifierKey.from(keyCode: 999) == nil)
    }

    @Test func singleModifierFlagDistinction() {
        // Holding Left Option: device bit 0x20 is set, 0x40 is not
        let leftOptionFlags = CGEventFlags(rawValue: 0x00080020)
        #expect(SingleModifierKey.leftOption.isPressed(flags: leftOptionFlags) == true)
        #expect(SingleModifierKey.rightOption.isPressed(flags: leftOptionFlags) == false)

        // Holding Right Option: device bit 0x40 is set, 0x20 is not
        let rightOptionFlags = CGEventFlags(rawValue: 0x00080040)
        #expect(SingleModifierKey.rightOption.isPressed(flags: rightOptionFlags) == true)
        #expect(SingleModifierKey.leftOption.isPressed(flags: rightOptionFlags) == false)
    }

    @Test func nativeHotKeyManagerTriggerPersistence() {
        let manager = NativeHotKeyManager.shared
        let original = manager.trigger
        defer { manager.trigger = original }

        manager.trigger = .singleModifier(.fn)
        #expect(manager.trigger == .singleModifier(.fn))
        #expect(manager.displayName() == "Fn")

        manager.trigger = .singleModifier(.rightOption)
        #expect(manager.trigger == .singleModifier(.rightOption))
        #expect(manager.displayName() == SingleModifierKey.rightOption.displayName)

        manager.trigger = .combination(keyCode: 49, modifiers: 2048)
        #expect(manager.trigger == .combination(keyCode: 49, modifiers: 2048))
        #expect(manager.displayName().contains("Space"))
    }

    @Test func pendingTriggerHandling() {
        let manager = NativeHotKeyManager.shared
        let original = manager.trigger
        defer { manager.trigger = original }

        manager.register(trigger: .singleModifier(.fn))
        #expect(manager.pendingTrigger == nil)

        let invalidCombo = HotKeyTrigger.combination(keyCode: 99999, modifiers: 0)
        let success = manager.register(trigger: invalidCombo)
        if !success {
            #expect(manager.pendingTrigger == nil)
        }
    }

    @Test func singleModifierWithoutAccessibilityExplainsAndRetries() {
        let manager = NativeHotKeyManager.shared
        let settings = HotKeySettings.shared
        let original = settings.trigger
        let originalCheck = manager.isAccessibilityTrusted
        let originalRequest = settings.requestAccessibility
        var requested = 0
        defer {
            manager.isAccessibilityTrusted = originalCheck
            settings.requestAccessibility = originalRequest
            settings.setPreset(original)
        }
        manager.isAccessibilityTrusted = { false }
        settings.requestAccessibility = { requested += 1 }

        let assigned = settings.setPreset(.singleModifier(.fn))

        #expect(assigned == false)
        #expect(requested == 1)
        #expect(manager.pendingTrigger == .singleModifier(.fn))
        #expect(settings.warningMessage != nil, "без прав пользователь должен видеть причину")

        // Права появились: ожидающая клавиша встаёт сама, причина уходит
        manager.isAccessibilityTrusted = { true }
        manager.register()

        #expect(settings.trigger == .singleModifier(.fn))
        #expect(settings.hotKeyName == "Fn")
        #expect(settings.warningMessage == nil)
    }

    @Test func pendingSingleModifierRegistersWhenAccessArrivesWithoutActivation() async throws {
        let manager = NativeHotKeyManager.shared
        let settings = HotKeySettings.shared
        let original = settings.trigger
        let originalCheck = manager.isAccessibilityTrusted
        let originalRequest = settings.requestAccessibility
        let originalInterval = manager.pendingRetryInterval
        defer {
            manager.isAccessibilityTrusted = originalCheck
            manager.pendingRetryInterval = originalInterval
            settings.requestAccessibility = originalRequest
            settings.setPreset(original)
        }
        manager.pendingRetryInterval = 0.05
        manager.isAccessibilityTrusted = { false }
        settings.requestAccessibility = {}

        settings.setPreset(.singleModifier(.fn))
        #expect(manager.pendingTrigger == .singleModifier(.fn))

        // Права появились спустя время, окно приложения при этом не активировалось
        manager.isAccessibilityTrusted = { true }
        var waited = 0
        while manager.pendingTrigger != nil && waited < 40 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }

        #expect(manager.pendingTrigger == nil, "ожидающая клавиша должна встать сама")
        #expect(settings.trigger == .singleModifier(.fn))
        #expect(settings.warningMessage == nil)
    }

    @Test func unsupportedModifierFallsBackToNone() {
        let manager = NativeHotKeyManager.shared
        let original = manager.trigger
        defer { manager.trigger = original }

        AppEnvironment.defaults.set("modifier", forKey: "hotkey.type")
        AppEnvironment.defaults.set(57, forKey: "hotkey.modifierKeyCode") // Legacy Caps Lock code

        #expect(manager.trigger == .none)
        #expect(manager.displayName() == "Не назначено")
    }

    @Test func fnToggleModeEventTap() async throws {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        let originalPressed = manager.onHotKeyPressed
        let originalReleased = manager.onHotKeyReleased
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
            manager.onHotKeyPressed = originalPressed
            manager.onHotKeyReleased = originalReleased
            manager.resetModifierState()
        }

        manager.setTrigger(.singleModifier(.fn))
        manager.mode = .toggle

        var pressedCount = 0
        manager.onHotKeyPressed = {
            pressedCount += 1
        }
        manager.onHotKeyReleased = {}

        // Fn down
        let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        eventDown.flags = [.maskSecondaryFn, CGEventFlags(rawValue: 0x00800000)]
        manager.handleEventTap(type: .flagsChanged, event: eventDown)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pressedCount == 1)

        // Fn up
        let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)!
        eventUp.flags = []
        manager.handleEventTap(type: .flagsChanged, event: eventUp)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pressedCount == 1)

        // Fn down again
        manager.handleEventTap(type: .flagsChanged, event: eventDown)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pressedCount == 2)
    }

    @Test func fnPushToTalkModeEventTap() async throws {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        let originalPressed = manager.onHotKeyPressed
        let originalReleased = manager.onHotKeyReleased
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
            manager.onHotKeyPressed = originalPressed
            manager.onHotKeyReleased = originalReleased
            manager.resetModifierState()
        }

        manager.setTrigger(.singleModifier(.fn))
        manager.mode = .pushToTalk

        var pressedCount = 0
        var releasedCount = 0
        manager.onHotKeyPressed = {
            pressedCount += 1
        }
        manager.onHotKeyReleased = {
            releasedCount += 1
        }

        // 1st press down: starts recording
        let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true)!
        eventDown.flags = [.maskSecondaryFn, CGEventFlags(rawValue: 0x00800000)]
        manager.handleEventTap(type: .flagsChanged, event: eventDown)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pressedCount == 1)
        #expect(releasedCount == 0)

        // Key up: stops recording
        let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)!
        eventUp.flags = []
        manager.handleEventTap(type: .flagsChanged, event: eventUp)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pressedCount == 1)
        #expect(releasedCount == 1)
    }

    // MARK: - Shift при нажатии и сочетание Carbon

    private func withFnToggle(_ body: (NativeHotKeyManager) async throws -> Void) async rethrows {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        let originalPressed = manager.onHotKeyPressed
        let originalReleased = manager.onHotKeyReleased
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
            manager.onHotKeyPressed = originalPressed
            manager.onHotKeyReleased = originalReleased
            manager.resetModifierState()
        }
        manager.setTrigger(.singleModifier(.fn))
        manager.mode = .toggle
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

    /// Shift, зажатый до Fn, ничего не меняет: это обычное нажатие.
    @Test func fnWithShiftIsPlainPress() async throws {
        try await withFnToggle { manager in
            var pressedCount = 0
            manager.onHotKeyPressed = { pressedCount += 1 }
            try await pressFn(manager, withShift: true)
            #expect(pressedCount == 1)
        }
    }

    @Test func fnWithoutShiftIsPlainPress() async throws {
        try await withFnToggle { manager in
            var pressedCount = 0
            manager.onHotKeyPressed = { pressedCount += 1 }
            try await pressFn(manager, withShift: false)
            #expect(pressedCount == 1)
        }
    }

    /// Нажатие и отпускание сочетания Carbon доходят до обработчиков ровно по разу.
    @Test func carbonHotKeyPressAndReleaseReachCallbacks() {
        let manager = NativeHotKeyManager.shared
        let originalPressed = manager.onHotKeyPressed
        let originalReleased = manager.onHotKeyReleased
        defer {
            manager.onHotKeyPressed = originalPressed
            manager.onHotKeyReleased = originalReleased
        }
        var pressedCount = 0
        var releasedCount = 0
        manager.onHotKeyPressed = { pressedCount += 1 }
        manager.onHotKeyReleased = { releasedCount += 1 }

        manager.handleCarbonHotKey(pressed: true)
        manager.handleCarbonHotKey(pressed: false)
        #expect(pressedCount == 1)
        #expect(releasedCount == 1)
    }
}

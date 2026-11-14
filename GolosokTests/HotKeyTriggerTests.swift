import Testing
import Foundation
import CoreGraphics
@testable import Golosok

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

    @Test func singleModifierDisplayNames() {
        #expect(SingleModifierKey.fn.displayName == "Fn")
        #expect(SingleModifierKey.rightOption.displayName == "Правый ⌥")
        #expect(SingleModifierKey.leftOption.displayName == "Левый ⌥")
        #expect(SingleModifierKey.rightCommand.displayName == "Правый ⌘")
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

    @Test func hotKeyTriggerDisplayName() {
        let fnTrigger = HotKeyTrigger.singleModifier(.fn)
        #expect(fnTrigger.displayName == "Fn")
        let comboTrigger = HotKeyTrigger.combination(keyCode: 49, modifiers: 2048)
        #expect(comboTrigger.displayName.contains("Space"))
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

    @Test func hotKeySettingsPresets() {
        let settings = HotKeySettings.shared
        let original = settings.trigger
        defer { settings.setPreset(original) }

        settings.setPreset(.singleModifier(.fn))
        #expect(settings.hotKeyName == "Fn")

        settings.setPreset(.singleModifier(.rightOption))
        #expect(settings.hotKeyName == SingleModifierKey.rightOption.displayName)

        settings.reset()
        #expect(settings.hotKeyName.contains("Space"))
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

    @Test func unsupportedModifierFallsBackToFn() {
        let manager = NativeHotKeyManager.shared
        let original = manager.trigger
        defer { manager.trigger = original }

        UserDefaults.standard.set("modifier", forKey: "hotkey.type")
        UserDefaults.standard.set(57, forKey: "hotkey.modifierKeyCode") // Legacy Caps Lock code

        #expect(manager.trigger == .singleModifier(.fn))
        #expect(manager.displayName() == "Fn")
    }

    @Test func fnToggleModeEventTap() {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
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
        #expect(pressedCount == 1)

        // Fn up
        let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)!
        eventUp.flags = []
        manager.handleEventTap(type: .flagsChanged, event: eventUp)
        #expect(pressedCount == 1)

        // Fn down again
        manager.handleEventTap(type: .flagsChanged, event: eventDown)
        #expect(pressedCount == 2)
    }

    @Test func fnPushToTalkModeEventTap() {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
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
        #expect(pressedCount == 1)
        #expect(releasedCount == 0)

        // Key up: stops recording
        let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)!
        eventUp.flags = []
        manager.handleEventTap(type: .flagsChanged, event: eventUp)
        #expect(pressedCount == 1)
        #expect(releasedCount == 1)
    }
}

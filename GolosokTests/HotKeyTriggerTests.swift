import Testing
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
        #expect(SingleModifierKey.from(keyCode: 57) == .capsLock)
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

        // Caps Lock physical press has bit 0x80 set
        let capsLockDownFlags = CGEventFlags(rawValue: 0x80)
        #expect(SingleModifierKey.capsLock.isPressed(flags: capsLockDownFlags) == true)
        let capsLockUpFlags = CGEventFlags(rawValue: 0x00)
        #expect(SingleModifierKey.capsLock.isPressed(flags: capsLockUpFlags) == false)
        // Caps Lock latched ON but physical key released (0x80 not set, maskAlphaShift set)
        let capsLockLatchedFlags = CGEventFlags.maskAlphaShift
        #expect(SingleModifierKey.capsLock.isPressed(flags: capsLockLatchedFlags) == false)
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

        settings.setPreset(.singleModifier(.capsLock))
        #expect(settings.trigger == .singleModifier(.capsLock))
        #expect(settings.hotKeyName == "Caps Lock")
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

    @Test func capsLockToggleModeEventTap() {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
            manager.resetModifierState()
        }

        manager.setTrigger(.singleModifier(.capsLock))
        manager.mode = .toggle
        manager.lastCapsLockState = false

        var pressedCount = 0
        manager.onHotKeyPressed = {
            pressedCount += 1
        }
        manager.onHotKeyReleased = {}

        // 1st press: Caps Lock turns ON (eventKeyCode 57, maskAlphaShift set)
        let event1 = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true)!
        event1.flags = .maskAlphaShift
        manager.handleEventTap(type: .flagsChanged, event: event1)
        #expect(pressedCount == 1)

        // 2nd press: Caps Lock turns OFF (even if eventKeyCode is 0, maskAlphaShift cleared)
        let event2 = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        event2.flags = []
        manager.handleEventTap(type: .flagsChanged, event: event2)
        #expect(pressedCount == 2)

        // 3rd press: Caps Lock turns ON again
        let event3 = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true)!
        event3.flags = .maskAlphaShift
        manager.handleEventTap(type: .flagsChanged, event: event3)
        #expect(pressedCount == 3)
    }

    @Test func capsLockPushToTalkModeEventTap() {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        let originalMode = manager.mode
        defer {
            manager.trigger = originalTrigger
            manager.mode = originalMode
            manager.resetModifierState()
        }

        manager.setTrigger(.singleModifier(.capsLock))
        manager.mode = .pushToTalk
        manager.lastCapsLockState = false

        var pressedCount = 0
        var releasedCount = 0
        manager.onHotKeyPressed = {
            pressedCount += 1
        }
        manager.onHotKeyReleased = {
            releasedCount += 1
        }

        // 1st press: Starts recording
        let event1 = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true)!
        event1.flags = .maskAlphaShift
        manager.handleEventTap(type: .flagsChanged, event: event1)
        #expect(pressedCount == 1)
        #expect(releasedCount == 0)

        // 2nd press: Stops recording
        let event2 = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        event2.flags = []
        manager.handleEventTap(type: .flagsChanged, event: event2)
        #expect(pressedCount == 1)
        #expect(releasedCount == 1)

        // 3rd press: Starts recording again
        let event3 = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true)!
        event3.flags = .maskAlphaShift
        manager.handleEventTap(type: .flagsChanged, event: event3)
        #expect(pressedCount == 2)
        #expect(releasedCount == 1)

        manager.resetModifierState()
    }

    @Test func otherModifierIgnoredWhenCapsLockConfigured() {
        let manager = NativeHotKeyManager.shared
        let originalTrigger = manager.trigger
        defer {
            manager.trigger = originalTrigger
            manager.resetModifierState()
        }

        manager.setTrigger(.singleModifier(.capsLock))
        manager.lastCapsLockState = false

        var pressedCount = 0
        manager.onHotKeyPressed = { pressedCount += 1 }

        // User presses Option while Caps Lock is configured
        let optionEvent = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true)!
        optionEvent.flags = .maskAlternate
        manager.handleEventTap(type: .flagsChanged, event: optionEvent)
        #expect(pressedCount == 0)
    }
}

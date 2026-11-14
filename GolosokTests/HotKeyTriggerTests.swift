import Testing
import CoreGraphics
@testable import Golosok

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

    @Test func hotKeyTriggerDisplayName() {
        let fnTrigger = HotKeyTrigger.singleModifier(.fn)
        #expect(fnTrigger.displayName == "Fn")
        let comboTrigger = HotKeyTrigger.combination(keyCode: 49, modifiers: 2048)
        #expect(comboTrigger.displayName.contains("Space"))
    }
}

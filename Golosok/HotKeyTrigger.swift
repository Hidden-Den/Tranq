import Foundation
import CoreGraphics
import Carbon

public enum SingleModifierKey: UInt32, CaseIterable, Codable, Sendable {
    case fn = 63
    case rightOption = 61
    case leftOption = 58
    case rightCommand = 54
    case leftCommand = 55
    case rightControl = 62
    case leftControl = 59
    case rightShift = 60
    case leftShift = 56
    case capsLock = 57

    public static func from(keyCode: UInt32) -> SingleModifierKey? {
        SingleModifierKey(rawValue: keyCode)
    }

    public var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Правый ⌥"
        case .leftOption: return "Левый ⌥"
        case .rightCommand: return "Правый ⌘"
        case .leftCommand: return "Левый ⌘"
        case .rightControl: return "Правый ⌃"
        case .leftControl: return "Левый ⌃"
        case .rightShift: return "Правый ⇧"
        case .leftShift: return "Левый ⇧"
        case .capsLock: return "Caps Lock"
        }
    }

    public func isPressed(flags: CGEventFlags) -> Bool {
        switch self {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .rightOption, .leftOption:
            return flags.contains(.maskAlternate)
        case .rightCommand, .leftCommand:
            return flags.contains(.maskCommand)
        case .rightControl, .leftControl:
            return flags.contains(.maskControl)
        case .rightShift, .leftShift:
            return flags.contains(.maskShift)
        case .capsLock:
            return flags.contains(.maskAlphaShift)
        }
    }
}

public enum HotKeyTrigger: Equatable, Codable, Sendable {
    case combination(keyCode: UInt32, modifiers: UInt32)
    case singleModifier(SingleModifierKey)

    public var displayName: String {
        switch self {
        case .singleModifier(let key):
            return key.displayName
        case .combination(let keyCode, let modifiers):
            var prefix = ""
            if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
            let name = Self.keyName(keyCode)
            return prefix.isEmpty ? name : "\(prefix) + \(name)"
        }
    }

    public static func keyName(_ keyCode: UInt32) -> String {
        let special: [UInt32: String] = [
            49: "Space", 48: "Tab", 51: "⌫", 53: "⎋", 36: "↩", 76: "⏎",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: "."
        ]
        return special[keyCode] ?? String(format: "K%u", keyCode)
    }
}

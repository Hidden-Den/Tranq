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

    public static func from(keyCode: UInt32) -> SingleModifierKey? {
        SingleModifierKey(rawValue: keyCode)
    }

    public var displayName: String {
        switch self {
        case .fn:
            return "Fn"
        case .rightOption:
            return NSLocalizedString("HotKey.Modifier.RightOption", value: "Правый ⌥", comment: "Right Option")
        case .leftOption:
            return NSLocalizedString("HotKey.Modifier.LeftOption", value: "Левый ⌥", comment: "Left Option")
        case .rightCommand:
            return NSLocalizedString("HotKey.Modifier.RightCommand", value: "Правый ⌘", comment: "Right Command")
        case .leftCommand:
            return NSLocalizedString("HotKey.Modifier.LeftCommand", value: "Левый ⌘", comment: "Left Command")
        case .rightControl:
            return NSLocalizedString("HotKey.Modifier.RightControl", value: "Правый ⌃", comment: "Right Control")
        case .leftControl:
            return NSLocalizedString("HotKey.Modifier.LeftControl", value: "Левый ⌃", comment: "Left Control")
        case .rightShift:
            return NSLocalizedString("HotKey.Modifier.RightShift", value: "Правый ⇧", comment: "Right Shift")
        case .leftShift:
            return NSLocalizedString("HotKey.Modifier.LeftShift", value: "Левый ⇧", comment: "Left Shift")
        }
    }

    /// Device-dependent bitmask from IOKit (`IOLLEvent.h`)
    public var deviceMask: UInt64 {
        switch self {
        case .fn: return 0x00800000          // NX_SECONDARYFNMASK
        case .rightOption: return 0x00000040 // NX_DEVICERALTKEYMASK
        case .leftOption: return 0x00000020  // NX_DEVICELALTKEYMASK
        case .rightCommand: return 0x00000010 // NX_DEVICERCMDKEYMASK
        case .leftCommand: return 0x00000008  // NX_DEVICELCMDKEYMASK
        case .rightControl: return 0x00002000 // NX_DEVICERCTLKEYMASK
        case .leftControl: return 0x00000001  // NX_DEVICELCTLKEYMASK
        case .rightShift: return 0x00000004   // NX_DEVICERSHIFTKEYMASK
        case .leftShift: return 0x00000002    // NX_DEVICELSHIFTKEYMASK
        }
    }

    public func isPressed(flags: CGEventFlags) -> Bool {
        if (flags.rawValue & deviceMask) != 0 {
            return true
        }
        // Fallback for virtual or non-Apple keyboards omitting device bits
        switch self {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .rightOption, .leftOption:
            return (flags.rawValue & 0x60) == 0 && flags.contains(.maskAlternate)
        case .rightCommand, .leftCommand:
            return (flags.rawValue & 0x18) == 0 && flags.contains(.maskCommand)
        case .rightControl, .leftControl:
            return (flags.rawValue & 0x2001) == 0 && flags.contains(.maskControl)
        case .rightShift, .leftShift:
            return (flags.rawValue & 0x06) == 0 && flags.contains(.maskShift)
        }
    }
}

public enum HotKeyTrigger: Equatable, Codable, Sendable {
    case none
    case combination(keyCode: UInt32, modifiers: UInt32)
    case singleModifier(SingleModifierKey)

    public static let optionSpace = HotKeyTrigger.combination(keyCode: 49, modifiers: UInt32(optionKey))
    public static let fnKey = HotKeyTrigger.singleModifier(.fn)
    public static let rightOptionKey = HotKeyTrigger.singleModifier(.rightOption)

    public var displayName: String {
        switch self {
        case .none:
            return NSLocalizedString("HotKey.None", value: "Не назначено", comment: "No hotkey assigned")
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

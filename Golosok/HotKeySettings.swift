import SwiftUI
import AppKit
import Carbon

public final class HotKeySettings: ObservableObject {
    public static let shared = HotKeySettings()

    @Published public var mode: HotKeyMode {
        didSet { NativeHotKeyManager.shared.mode = mode }
    }
    @Published public var trigger: HotKeyTrigger
    @Published public var hotKeyName: String = ""
    @Published public var isCapturing = false
    @Published public var isTaken = false
    @Published public var warningMessage: String? = nil

    private var monitor: Any?
    private var pendingSingleModifier: SingleModifierKey?

    private init() {
        mode = NativeHotKeyManager.shared.mode
        trigger = NativeHotKeyManager.shared.trigger
        hotKeyName = NativeHotKeyManager.shared.displayName()
    }

    public func refreshName() {
        trigger = NativeHotKeyManager.shared.trigger
        hotKeyName = NativeHotKeyManager.shared.displayName()
    }

    public var isConfigured: Bool {
        trigger != .none
    }

    @discardableResult
    public func setPreset(_ preset: HotKeyTrigger) -> Bool {
        endCapture()
        let succeeded = NativeHotKeyManager.shared.register(trigger: preset)
        if succeeded {
            self.trigger = preset
            self.isTaken = false
            refreshName()
            return true
        } else {
            switch preset {
            case .combination:
                self.isTaken = true
            case .singleModifier:
                self.isTaken = false
                PermissionManager.shared.requestAccessibilityPermission()
            case .none:
                self.isTaken = false
            }
            return false
        }
    }

    public func reset() {
        setPreset(.none)
    }

    public func clear() {
        setPreset(.none)
    }

    public func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        isTaken = false
        warningMessage = nil
        pendingSingleModifier = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .keyDown && event.keyCode == 53 {
                self.endCapture()
                return event
            }

            if event.keyCode == 57 {
                self.warningMessage = NSLocalizedString("HotKey.CapsLockUnsupported", value: "Caps Lock не поддерживается", comment: "Caps Lock unsupported warning")
                return nil
            }

            if event.type == .flagsChanged {
                let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))

                // Если модификатор был зажат и теперь отпущен — фиксируем его
                if let pending = self.pendingSingleModifier {
                    if !pending.isPressed(flags: flags) {
                        self.pendingSingleModifier = nil
                        self.setPreset(.singleModifier(pending))
                        return nil
                    }
                }

                if let modKey = SingleModifierKey.from(keyCode: UInt32(event.keyCode)) {
                    if modKey.isPressed(flags: flags) {
                        self.pendingSingleModifier = modKey
                    }
                } else if flags.contains(.maskSecondaryFn) || (flags.rawValue & SingleModifierKey.fn.deviceMask) != 0 {
                    self.pendingSingleModifier = .fn
                }
                return event
            }

            if event.type == .keyDown {
                // A key was pressed down while holding modifiers: cancel single-modifier candidate
                self.pendingSingleModifier = nil

                let allowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                let mods = event.modifierFlags.intersection(allowed)
                guard !mods.isEmpty, let carbon = self.carbonModifiers(from: mods) else {
                    return event
                }
                let keyCode = UInt32(event.keyCode)
                let newTrigger = HotKeyTrigger.combination(keyCode: keyCode, modifiers: carbon)
                self.setPreset(newTrigger)
                return nil
            }

            return event
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32? {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    public func endCapture() {
        pendingSingleModifier = nil
        warningMessage = nil
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isCapturing = false
    }
}

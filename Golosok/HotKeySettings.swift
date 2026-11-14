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
            }
            return false
        }
    }

    public func reset() {
        setPreset(.combination(keyCode: 49, modifiers: UInt32(optionKey)))
    }

    public func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        isTaken = false
        pendingSingleModifier = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .keyDown && event.keyCode == 53 {
                self.endCapture()
                return event
            }

            if event.type == .flagsChanged {
                if let modKey = SingleModifierKey.from(keyCode: UInt32(event.keyCode)) {
                    if modKey == .capsLock {
                        self.setPreset(.singleModifier(.capsLock))
                        return nil
                    }

                    let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                    if modKey.isPressed(flags: flags) {
                        // Modifier pressed down: defer committing in case user is starting a combination
                        self.pendingSingleModifier = modKey
                    } else {
                        // Modifier released
                        if self.pendingSingleModifier == modKey {
                            self.pendingSingleModifier = nil
                            self.setPreset(.singleModifier(modKey))
                            return nil
                        }
                        self.pendingSingleModifier = nil
                    }
                }
                return event
            }

            if event.type == .keyDown {
                if event.keyCode == 57 {
                    self.setPreset(.singleModifier(.capsLock))
                    return nil
                }
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
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isCapturing = false
    }
}

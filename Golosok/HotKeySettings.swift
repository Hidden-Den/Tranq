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

    private init() {
        mode = NativeHotKeyManager.shared.mode
        trigger = NativeHotKeyManager.shared.trigger
        hotKeyName = NativeHotKeyManager.shared.displayName()
    }

    public func refreshName() {
        trigger = NativeHotKeyManager.shared.trigger
        hotKeyName = NativeHotKeyManager.shared.displayName()
    }

    public func setPreset(_ preset: HotKeyTrigger) {
        NativeHotKeyManager.shared.trigger = preset
        trigger = preset
        refreshName()
    }

    public func reset() {
        setPreset(.combination(keyCode: 49, modifiers: UInt32(optionKey)))
    }

    public var isFnPreset: Bool {
        trigger == .singleModifier(.fn)
    }

    public var isRightOptionPreset: Bool {
        trigger == .singleModifier(.rightOption)
    }

    public var isDefaultPreset: Bool {
        if case .combination(let kc, _) = trigger, kc == 49 {
            return true
        }
        return false
    }

    public func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        isTaken = false

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .keyDown && event.keyCode == 53 {
                self.endCapture()
                return event
            }

            if event.type == .flagsChanged {
                if let modKey = SingleModifierKey.from(keyCode: UInt32(event.keyCode)) {
                    let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                    if modKey.isPressed(flags: flags) {
                        self.setPreset(.singleModifier(modKey))
                        self.endCapture()
                        return nil
                    }
                }
                return event
            }

            if event.type == .keyDown {
                let allowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                let mods = event.modifierFlags.intersection(allowed)
                guard !mods.isEmpty, let carbon = self.carbonModifiers(from: mods) else {
                    return event
                }
                let keyCode = UInt32(event.keyCode)
                let newTrigger = HotKeyTrigger.combination(keyCode: keyCode, modifiers: carbon)
                let succeeded = (NativeHotKeyManager.shared.trigger == newTrigger)
                    || NativeHotKeyManager.shared.setHotKey(keyCode: keyCode, modifiers: carbon)
                self.isTaken = !succeeded
                if succeeded {
                    self.trigger = newTrigger
                    self.refreshName()
                }
                self.endCapture()
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
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isCapturing = false
    }
}

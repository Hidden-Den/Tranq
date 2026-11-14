import Foundation
import Carbon
import AppKit
import CoreGraphics

public enum HotKeyKey: String {
    case space = "space"
    case command = "command"
}

public enum HotKeyMode: String, CaseIterable, Identifiable {
    case toggle = "toggle"
    case pushToTalk = "pushToTalk"
    public var id: String { rawValue }
}

public class NativeHotKeyManager {
    public static let shared = NativeHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isModifierActive: Bool = false

    public var onHotKeyPressed: (() -> Void)?
    public var onHotKeyReleased: (() -> Void)?

    private init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            guard let eventRef else { return noErr }
            switch GetEventKind(eventRef) {
            case UInt32(kEventHotKeyPressed): NativeHotKeyManager.shared.onHotKeyPressed?()
            case UInt32(kEventHotKeyReleased): NativeHotKeyManager.shared.onHotKeyReleased?()
            default: break
            }
            return noErr
        }, 2, &eventTypes, nil, &eventHandlerRef)
    }

    public var trigger: HotKeyTrigger {
        get {
            let type = UserDefaults.standard.string(forKey: "hotkey.type") ?? "combo"
            if type == "modifier",
               let key = SingleModifierKey.from(keyCode: UInt32(UserDefaults.standard.integer(forKey: "hotkey.modifierKeyCode"))) {
                return .singleModifier(key)
            }
            return .combination(keyCode: keyCode, modifiers: modifierFlags)
        }
        set {
            switch newValue {
            case .singleModifier(let key):
                UserDefaults.standard.set("modifier", forKey: "hotkey.type")
                UserDefaults.standard.set(Int(key.rawValue), forKey: "hotkey.modifierKeyCode")
            case .combination(let kCode, let mods):
                UserDefaults.standard.set("combo", forKey: "hotkey.type")
                self.keyCode = kCode
                self.modifierFlags = mods
            }
            register()
        }
    }

    public var keyCode: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "hotkey.keyCode")) == 0 ? 49 : UInt32(UserDefaults.standard.integer(forKey: "hotkey.keyCode")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkey.keyCode") }
    }

    public var modifierFlags: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "hotkey.modifiers")) == 0 ? UInt32(optionKey) : UInt32(UserDefaults.standard.integer(forKey: "hotkey.modifiers")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkey.modifiers") }
    }

    public var mode: HotKeyMode {
        get { HotKeyMode(rawValue: UserDefaults.standard.string(forKey: "hotkey.mode") ?? "") ?? .toggle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey.mode") }
    }

    public func setTrigger(_ trigger: HotKeyTrigger) {
        self.trigger = trigger
    }

    public func register() {
        unregister()
        switch trigger {
        case .combination(let kCode, let mods):
            let hotKeyID = EventHotKeyID(signature: OSType(0x474C534B), id: 1)
            let status = RegisterEventHotKey(kCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            if status != noErr {
                AppLogger.shared.error("HotKey", "Не удалось зарегистрировать горячую клавишу", details: "status \(status), комбинация \(displayName())")
                Telemetry.shared.event("hotkey_register_failed", ["error_detail": "status_\(status)"])
                NSLog("[HotKey] RegisterEventHotKey failed with status %d", status)
            } else {
                AppLogger.shared.info("HotKey", "Горячая клавиша зарегистрирована", details: displayName())
            }
        case .singleModifier(let key):
            registerEventTap(for: key)
        }
    }

    private func registerEventTap(for key: SingleModifierKey) {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<NativeHotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEventTap(proxy: proxy, type: type, event: event)
            },
            userInfo: observer
        ) else {
            AppLogger.shared.error("HotKey", "Не удалось создать CGEventTap", details: key.displayName)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        AppLogger.shared.info("HotKey", "CGEventTap зарегистрирован для модификатора", details: key.displayName)
    }

    private func handleEventTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard case .singleModifier(let key) = trigger else {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == key.rawValue else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = key.isPressed(flags: event.flags)
        if isDown {
            if !isModifierActive {
                isModifierActive = true
                DispatchQueue.main.async { [weak self] in
                    self?.onHotKeyPressed?()
                }
            }
        } else {
            if isModifierActive {
                isModifierActive = false
                DispatchQueue.main.async { [weak self] in
                    self?.onHotKeyReleased?()
                }
            }
        }

        return nil
    }

    public func setHotKey(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C534B), id: 1)
        var testRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &testRef)
        if status != noErr { return false }
        UnregisterEventHotKey(testRef!)
        self.trigger = .combination(keyCode: keyCode, modifiers: modifiers)
        return true
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                runLoopSource = nil
            }
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        isModifierActive = false
    }

    public func displayName() -> String {
        trigger.displayName
    }

    deinit {
        unregister()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }
}

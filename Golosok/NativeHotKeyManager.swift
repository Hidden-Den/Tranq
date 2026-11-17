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
    private var promptHotKeyRef: EventHotKeyRef?
    static let plainHotKeyID: UInt32 = 1
    static let promptHotKeyID: UInt32 = 2
    private var eventHandlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isModifierActive: Bool = false
    public private(set) var pendingTrigger: HotKeyTrigger?

    /// Аргумент `true`, если нажато сочетание для режима промпта: основная клавиша с Shift.
    public var onHotKeyPressed: ((_ promptRequested: Bool) -> Void)?
    public var onHotKeyReleased: (() -> Void)?
    /// Включён ли режим промпта. Тесты подменяют, чтобы не трогать общие настройки.
    var isPromptModeEnabled: () -> Bool = { VoiceIntelligenceSettings.shared.promptModeEnabled }
    public var isExternalRecordingActive: (() -> Bool)?

    private init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            guard let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID(signature: 0, id: NativeHotKeyManager.plainHotKeyID)
            let status = GetEventParameter(
                eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            // Не удалось прочитать id: ведём себя как раньше, без режима промпта
            let id = status == noErr ? hotKeyID.id : NativeHotKeyManager.plainHotKeyID
            switch GetEventKind(eventRef) {
            case UInt32(kEventHotKeyPressed): NativeHotKeyManager.shared.handleCarbonHotKey(id: id, pressed: true)
            case UInt32(kEventHotKeyReleased): NativeHotKeyManager.shared.handleCarbonHotKey(id: id, pressed: false)
            default: break
            }
            return noErr
        }, 2, &eventTypes, nil, &eventHandlerRef)

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.register()
        }
    }

    private var isTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTest") != nil
    }

    public var trigger: HotKeyTrigger {
        get {
            guard let type = AppEnvironment.defaults.string(forKey: "hotkey.type") else {
                return .none
            }
            if type == "none" {
                return .none
            }
            if type == "modifier" {
                let keyCode = UInt32(AppEnvironment.defaults.integer(forKey: "hotkey.modifierKeyCode"))
                if let key = SingleModifierKey.from(keyCode: keyCode) {
                    return .singleModifier(key)
                }
                return .none
            }
            if type == "combo" {
                return .combination(keyCode: keyCode, modifiers: modifierFlags)
            }
            return .none
        }
        set {
            saveTrigger(newValue)
            _ = register(trigger: newValue)
        }
    }

    public var keyCode: UInt32 {
        get {
            guard AppEnvironment.defaults.object(forKey: "hotkey.keyCode") != nil else { return 49 }
            return UInt32(AppEnvironment.defaults.integer(forKey: "hotkey.keyCode"))
        }
        set { AppEnvironment.defaults.set(Int(newValue), forKey: "hotkey.keyCode") }
    }

    public var modifierFlags: UInt32 {
        get {
            guard AppEnvironment.defaults.object(forKey: "hotkey.modifiers") != nil else { return UInt32(optionKey) }
            return UInt32(AppEnvironment.defaults.integer(forKey: "hotkey.modifiers"))
        }
        set { AppEnvironment.defaults.set(Int(newValue), forKey: "hotkey.modifiers") }
    }

    public var mode: HotKeyMode {
        get { HotKeyMode(rawValue: AppEnvironment.defaults.string(forKey: "hotkey.mode") ?? "") ?? .toggle }
        set { AppEnvironment.defaults.set(newValue.rawValue, forKey: "hotkey.mode") }
    }

    public func setTrigger(_ trigger: HotKeyTrigger) {
        self.trigger = trigger
    }

    @discardableResult
    public func register(trigger: HotKeyTrigger) -> Bool {
        let previousTrigger = self.trigger
        let success = applyRegistration(for: trigger)

        if success {
            saveTrigger(trigger)
            pendingTrigger = nil
        } else {
            switch trigger {
            case .singleModifier:
                pendingTrigger = trigger
            case .combination, .none:
                pendingTrigger = nil
            }
            if previousTrigger != trigger {
                _ = applyRegistration(for: previousTrigger)
            }
        }
        return success
    }

    private func applyRegistration(for trigger: HotKeyTrigger) -> Bool {
        unregister()
        switch trigger {
        case .none:
            AppLogger.shared.info("HotKey", "Горячая клавиша не назначена")
            return true
        case .combination(let kCode, let mods):
            let hotKeyID = EventHotKeyID(signature: OSType(0x474C534B), id: Self.plainHotKeyID)
            let status = RegisterEventHotKey(kCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            if status != noErr {
                AppLogger.shared.error("HotKey", "Не удалось зарегистрировать горячую клавишу", details: "status \(status), комбинация \(trigger.displayName)")
                NSLog("[HotKey] RegisterEventHotKey failed with status %d", status)
                return false
            } else {
                AppLogger.shared.info("HotKey", "Горячая клавиша зарегистрирована", details: trigger.displayName)
                registerPromptHotKey(for: trigger)
                return true
            }
        case .singleModifier(let key):
            return registerEventTap(for: key)
        }
    }

    public var isPromptHotKeyRegistered: Bool { promptHotKeyRef != nil }

    /// Нужно вызывать при смене клавиши и переключателя режима промпта.
    public func refreshPromptRegistration() {
        registerPromptHotKey(for: trigger)
    }

    /// Второе сочетание Carbon, основная клавиша с Shift, только если режим включён и Shift свободен.
    private func registerPromptHotKey(for trigger: HotKeyTrigger) {
        unregisterPromptHotKey()
        guard isPromptModeEnabled(),
              case .combination = trigger,
              case .combination(let kCode, let mods)? = trigger.promptVariant else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x474C534B), id: Self.promptHotKeyID)
        let status = RegisterEventHotKey(kCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &promptHotKeyRef)
        if status != noErr {
            promptHotKeyRef = nil
            AppLogger.shared.warn("HotKey", "Не удалось зарегистрировать сочетание для промпта", details: "status \(status)")
        }
    }

    private func unregisterPromptHotKey() {
        if let ref = promptHotKeyRef {
            UnregisterEventHotKey(ref)
            promptHotKeyRef = nil
        }
    }

    /// Нажатие или отпускание зарегистрированного сочетания Carbon. Id 2 это сочетание с Shift.
    func handleCarbonHotKey(id: UInt32, pressed: Bool) {
        if pressed {
            onHotKeyPressed?(id == Self.promptHotKeyID)
        } else {
            onHotKeyReleased?()
        }
    }

    public func register() {
        if let pending = pendingTrigger {
            if register(trigger: pending) {
                HotKeySettings.shared.refreshName()
            }
            return
        }
        _ = applyRegistration(for: trigger)
    }

    private func saveTrigger(_ trigger: HotKeyTrigger) {
        switch trigger {
        case .none:
            AppEnvironment.defaults.set("none", forKey: "hotkey.type")
        case .singleModifier(let key):
            AppEnvironment.defaults.set("modifier", forKey: "hotkey.type")
            AppEnvironment.defaults.set(Int(key.rawValue), forKey: "hotkey.modifierKeyCode")
        case .combination(let kCode, let mods):
            AppEnvironment.defaults.set("combo", forKey: "hotkey.type")
            self.keyCode = kCode
            self.modifierFlags = mods
        }
    }

    private var hasLoggedAccessibilityWarning = false

    private func registerEventTap(for key: SingleModifierKey) -> Bool {
        if isTestEnvironment {
            return true
        }

        guard AXIsProcessTrusted() else {
            if !hasLoggedAccessibilityWarning {
                hasLoggedAccessibilityWarning = true
                AppLogger.shared.warn("HotKey", "Ожидание прав Универсального доступа", details: key.displayName)
            }
            return false
        }
        hasLoggedAccessibilityWarning = false

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
            NSLog("[HotKey] CGEvent.tapCreate failed for %@", key.displayName)
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        AppLogger.shared.info("HotKey", "CGEventTap зарегистрирован для модификатора", details: key.displayName)
        return true
    }

    public func resetModifierState() {
        isModifierActive = false
    }

    private func dispatchToMain(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    @discardableResult
    func handleEventTap(proxy: CGEventTapProxy? = nil, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isModifierActive {
                isModifierActive = false
                dispatchToMain { [weak self] in
                    self?.onHotKeyReleased?()
                }
            }
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard case .singleModifier(let key) = trigger else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = key.isPressed(flags: event.flags)
        if isDown != isModifierActive {
            if isDown {
                let eventKeyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                if key == .fn || eventKeyCode == key.rawValue || (event.flags.rawValue & key.deviceMask) != 0 {
                    isModifierActive = true
                    // Shift нужно зажать до клавиши; сама клавиша Shift режим промпта не запускает
                    let promptRequested = isPromptModeEnabled()
                        && HotKeyTrigger.singleModifier(key).promptVariant != nil
                        && event.flags.contains(.maskShift)
                    dispatchToMain { [weak self] in
                        self?.onHotKeyPressed?(promptRequested)
                    }
                }
            } else {
                isModifierActive = false
                dispatchToMain { [weak self] in
                    self?.onHotKeyReleased?()
                }
            }
        }

        return Unmanaged.passUnretained(event)
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
        unregisterPromptHotKey()
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

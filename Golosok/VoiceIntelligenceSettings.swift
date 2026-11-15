import Foundation
import SwiftUI

public enum VoiceInputMode: String, CaseIterable, Identifiable {
    case smart = "smart"
    case direct = "direct"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smart: return String(localized: "Умная речь")
        case .direct: return String(localized: "Прямой ввод")
        }
    }

    public var subtitle: String {
        switch self {
        case .smart: return String(localized: "Синтез мыслей и очистка от паразитов")
        case .direct: return String(localized: "Дословная расшифровка без изменений")
        }
    }
}

public enum VoiceStyle: String, CaseIterable, Identifiable {
    case clean = "clean"
    case bullets = "bullets"
    case formal = "formal"
    case prompt = "prompt"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clean: return String(localized: "Чистая мысль")
        case .bullets: return String(localized: "Тезисы")
        case .formal: return String(localized: "Деловой стиль")
        case .prompt: return String(localized: "Промпт")
        }
    }

    public var icon: String {
        switch self {
        case .clean: return "sparkles"
        case .bullets: return "list.bullet"
        case .formal: return "briefcase"
        case .prompt: return "command"
        }
    }
}

public enum VoiceEngine: String, CaseIterable, Identifiable {
    case airGapped = "airGapped"
    case openRouter = "openRouter"
    case ollama = "ollama"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .airGapped: return String(localized: "Air-Gapped на устройстве")
        case .openRouter: return String(localized: "OpenRouter")
        case .ollama: return String(localized: "Ollama локально")
        }
    }

    public var subtitle: String {
        switch self {
        case .airGapped: return String(localized: "100% оффлайн на Apple Silicon")
        case .openRouter: return String(localized: "Быстрые облачные модели по ключу")
        case .ollama: return String(localized: "Локальный сервер Ollama или LM Studio")
        }
    }
}

public final class VoiceIntelligenceSettings: ObservableObject {
    public static let shared = VoiceIntelligenceSettings()

    private static let defaults = UserDefaults.standard

    @Published public var mode: VoiceInputMode {
        didSet { Self.defaults.set(mode.rawValue, forKey: "voice.mode") }
    }

    @Published public var style: VoiceStyle {
        didSet { Self.defaults.set(style.rawValue, forKey: "voice.style") }
    }

    @Published public var engine: VoiceEngine {
        didSet { Self.defaults.set(engine.rawValue, forKey: "voice.engine") }
    }

    @Published public var openRouterModel: String {
        didSet { Self.defaults.set(openRouterModel, forKey: "voice.openRouterModel") }
    }

    @Published public var localModel: String {
        didSet { Self.defaults.set(localModel, forKey: "voice.localModel") }
    }

    @Published public var adaptiveTimeoutSeconds: Double {
        didSet { Self.defaults.set(adaptiveTimeoutSeconds, forKey: "voice.timeout") }
    }

    @Published public var adaptiveAppProfilesEnabled: Bool {
        didSet { Self.defaults.set(adaptiveAppProfilesEnabled, forKey: "voice.adaptiveAppProfiles") }
    }

    @Published public var userTerms: [String] {
        didSet { Self.defaults.set(userTerms, forKey: "voice.userTerms") }
    }

    public func addUserTerm(_ term: String) {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !userTerms.contains(cleaned) else { return }
        userTerms.append(cleaned)
    }

    public func removeUserTerm(_ term: String) {
        userTerms.removeAll { $0 == term }
    }

    private init() {
        let storedMode = Self.defaults.string(forKey: "voice.mode") ?? VoiceInputMode.smart.rawValue
        self.mode = VoiceInputMode(rawValue: storedMode) ?? .smart

        let storedStyle = Self.defaults.string(forKey: "voice.style") ?? VoiceStyle.clean.rawValue
        self.style = VoiceStyle(rawValue: storedStyle) ?? .clean

        let storedEngine = Self.defaults.string(forKey: "voice.engine") ?? VoiceEngine.openRouter.rawValue
        self.engine = VoiceEngine(rawValue: storedEngine) ?? .openRouter

        self.openRouterModel = Self.defaults.string(forKey: "voice.openRouterModel") ?? "anthropic/claude-haiku-5.5"
        self.localModel = Self.defaults.string(forKey: "voice.localModel") ?? "Vikhr-Qwen-2.5-1.5B"
        self.adaptiveTimeoutSeconds = Self.defaults.double(forKey: "voice.timeout") > 0 ? Self.defaults.double(forKey: "voice.timeout") : 3.0
        self.adaptiveAppProfilesEnabled = Self.defaults.object(forKey: "voice.adaptiveAppProfiles") != nil ? Self.defaults.bool(forKey: "voice.adaptiveAppProfiles") : true
        self.userTerms = Self.defaults.stringArray(forKey: "voice.userTerms") ?? []
    }
}

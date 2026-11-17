import Foundation

/// Рекомендуемая локальная модель по памяти Mac. Только помечает модель в настройках
/// и не меняет выбор пользователя. Модели выбраны замером, см. docs/eval-local-models-2026-11.md.
enum SLMRecommendation {
    /// 15.5 ГиБ: Mac на 16 ГБ сообщает чуть меньше 16 ГиБ, но относится к классу 16.
    static let threshold: UInt64 = 16_642_998_272
    static let smallID = "gemma_4_e2b"
    static let largeID = "gemma_4_e4b_qat"

    static func memoryClass(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        physicalMemory < threshold ? 8 : 16
    }

    static func recommendedModelID(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        memoryClass(physicalMemory: physicalMemory) == 16 ? largeID : smallID
    }

    static func isRecommended(_ model: SLMModel, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        model.id == recommendedModelID(physicalMemory: physicalMemory)
    }

    /// Подпись в списке моделей: «Gemma 4 E4B · Рекомендуем» или «T-lite 2.1 · Нужно 16 ГБ».
    static func pickerLabel(for model: SLMModel, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        if isRecommended(model, physicalMemory: physicalMemory) {
            return "\(model.name) · \(String(localized: "Рекомендуем"))"
        }
        if model.memoryClassGB > memoryClass(physicalMemory: physicalMemory) {
            return "\(model.name) · \(String(localized: "Нужно 16 ГБ"))"
        }
        return model.name
    }
}

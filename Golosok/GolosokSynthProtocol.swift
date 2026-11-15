import Foundation

@objc(GolosokSynthProtocol)
public protocol GolosokSynthProtocol {
    /// Запуск синтеза мысли в изолированном XPC процессе
    func synthesize(
        prompt: String,
        systemPrompt: String,
        options: [String: Any],
        with reply: @escaping (String?, Error?) -> Void
    )

    /// Прогрев модели и кэширование системного промпта в Metal KV-кэше
    func prewarmModel(
        modelPath: String,
        with reply: @escaping (Bool) -> Void
    )

    /// Выгрузка весов из памяти (освобождение 100% RAM)
    func unloadModel(
        with reply: @escaping () -> Void
    )
}

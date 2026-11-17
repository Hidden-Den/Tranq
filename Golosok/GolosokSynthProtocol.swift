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

}

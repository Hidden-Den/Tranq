import Testing
import Foundation
@testable import Tranq

/// Что греется перед диктовкой. Решение проверяется чистой функцией: у прогрева
/// нет возвращаемого значения, а сеть в тестах трогать незачем.
struct PrewarmPlanTests {

    /// Внешний провайдер не греется. Греть на стороне API нечего: прогрев открывал
    /// только сокет, экономя 0,15 с рукопожатия, а к концу долгой диктовки шлюз
    /// успевал его закрыть, и запрос падал с -1005 на мёртвом соединении из пула.
    @Test func externalEngineWarmsNothing() {
        #expect(ThoughtSynthesizer.prewarmPlan(engine: .external, downloadedModelPath: "/models/gemma.gguf") == .nothing)
    }

    /// Локальной модели прогрев нужен по-настоящему: она поднимается в память секунды.
    @Test func localEngineWarmsTheDownloadedModel() {
        #expect(ThoughtSynthesizer.prewarmPlan(engine: .airGapped, downloadedModelPath: "/models/gemma.gguf")
                == .localModel(path: "/models/gemma.gguf"))
    }

    /// Модель не скачана: греть нечего, и незачем поднимать чужую на гигабайты памяти.
    @Test func localEngineWithoutModelWarmsNothing() {
        #expect(ThoughtSynthesizer.prewarmPlan(engine: .airGapped, downloadedModelPath: nil) == .nothing)
    }
}

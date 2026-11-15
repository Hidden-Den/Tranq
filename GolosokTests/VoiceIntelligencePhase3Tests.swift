//
//  VoiceIntelligencePhase3Tests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

struct VoiceIntelligencePhase3Tests {

    // MARK: - HardwareWatchdog

    @Test func hardwareWatchdogEvaluatesControlledDecisions() {
        // Контролируемое нормальное состояние оборудования: инференс разрешен
        let normalDecision = HardwareWatchdog.evaluateDecision(
            thermalState: .nominal,
            isLowPowerMode: false,
            freeMB: 2048
        )
        #expect(normalDecision == .allowed)

        // Контролируемый перегрев устройства: инференс запрещен
        let overheatDecision = HardwareWatchdog.evaluateDecision(
            thermalState: .critical,
            isLowPowerMode: false,
            freeMB: 2048
        )
        #expect(overheatDecision == .restricted(reason: "Критический перегрев устройства"))

        // Контролируемый режим энергосбережения: инференс запрещен
        let lowPowerDecision = HardwareWatchdog.evaluateDecision(
            thermalState: .nominal,
            isLowPowerMode: true,
            freeMB: 2048
        )
        #expect(lowPowerDecision == .restricted(reason: "Включен режим энергосбережения"))

        // Контролируемый дефицит памяти (< 1200 МБ): инференс запрещен
        let lowMemDecision = HardwareWatchdog.evaluateDecision(
            thermalState: .nominal,
            isLowPowerMode: false,
            freeMB: 512
        )
        #expect(lowMemDecision == .restricted(reason: "Недостаточно свободной оперативной памяти: 512 МБ"))

        // Неизвестный объем памяти (сбой системного пробинга): инференс запрещен
        let unknownMemDecision = HardwareWatchdog.evaluateDecision(
            thermalState: .nominal,
            isLowPowerMode: false,
            freeMB: nil
        )
        #expect(unknownMemDecision == .restricted(reason: "Не удалось определить объем свободной оперативной памяти"))
    }

    @Test func hardwareWatchdogRejectsCriticalThermalState() {
        let isSafe = HardwareWatchdog.isThermalStateSafe(state: .critical)
        #expect(!isSafe)

        let isSeriousSafe = HardwareWatchdog.isThermalStateSafe(state: .serious)
        #expect(!isSeriousSafe)

        let isNominalSafe = HardwareWatchdog.isThermalStateSafe(state: .nominal)
        #expect(isNominalSafe)

        let isFairSafe = HardwareWatchdog.isThermalStateSafe(state: .fair)
        #expect(isFairSafe)
    }

    // MARK: - SLMModelStore

    @Test func slmCatalogHasCuratedModels() {
        let catalog = SLMModelStore.catalog
        #expect(!catalog.isEmpty)
        #expect(catalog.contains { $0.id == "vikhr_1.5b" })
        #expect(catalog.contains { $0.id == "qvikhr_3_4b" })
        #expect(catalog.contains { $0.id == "vikhr_0.5b" })
        #expect(catalog.contains { $0.id == "qwen_3.5_0.8b" })
        #expect(catalog.contains { $0.id == "qwen_3.5_2b" })
        #expect(catalog.contains { $0.id == "llama_3.2_1b" })

        // Проверка fail-safe наличия нескольких источников у каждой модели
        for model in catalog {
            #expect(model.downloadURLs.count >= 2)
            #expect(model.downloadURL != nil)
        }

        // Проверка совместимости с legacy ID
        #expect(SLMModelStore.shared.model(named: "qwen_0.5b")?.id == "qwen_3.5_0.8b")
        #expect(SLMModelStore.shared.model(named: "qwen_1.5b")?.id == "qwen_3.5_2b")
        #expect(SLMModelStore.shared.model(named: "qwen_3.5_1.5b")?.id == "qwen_3.5_2b")
    }

    @Test func slmModelPathCalculationIsClean() {
        let model = SLMModelStore.catalog[0]
        let path = SLMModelStore.shared.localFileURL(for: model)
        #expect(path.path.contains("Golosok"))
        #expect(path.path.contains("models"))
        #expect(path.lastPathComponent == model.fileName)
    }

    @Test func slmModelStoreSupportsMultiSourceFailSafe() {
        for model in SLMModelStore.catalog {
            #expect(model.downloadURLs.count >= 2, "Каждая модель должна иметь как минимум 2 надежных источника")
            for url in model.downloadURLs {
                #expect(url.scheme == "https")
                #expect(url.host?.contains("huggingface.co") == true)
            }
        }
    }

    // MARK: - LocalSynthServiceClient fallback

    @Test func localSynthClientFallsBackGracefullyWithoutDaemon() async {
        let client = LocalSynthServiceClient.shared
        client.mockService = nil

        // Когда XPC сервис не подключен в системе, synthesize обязан детерминированно возвращать nil
        if !client.isServiceAvailable {
            let result = await client.synthesize(
                transcript: "Тестовая надиктованная фраза",
                stylePrompt: "Очисти от мусора"
            )
            #expect(result == nil, "При отсутствии XPC-демона инференс должен мгновенно возвращать nil для отката на этап 1")
        }

        // Проверка полного сквозного отката ThoughtSynthesizer на этап 1 в режиме airGapped
        let settings = VoiceIntelligenceSettings.shared
        let originalEngine = settings.engine
        settings.engine = .airGapped
        defer { settings.engine = originalEngine }

        await withCheckedContinuation { continuation in
            ThoughtSynthesizer.shared.synthesize(
                rawText: "эээ ну короче тестирование локального отката",
                style: .clean
            ) { finalText, isFallback in
                #expect(isFallback == true, "При отказе локального демона фреймворк обязан сообщать о fallback")
                #expect(!finalText.isEmpty)
                #expect(!finalText.contains("эээ"))
                continuation.resume()
            }
        }
    }
}

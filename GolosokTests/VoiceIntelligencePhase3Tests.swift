//
//  VoiceIntelligencePhase3Tests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

struct VoiceIntelligencePhase3Tests {

    // MARK: - HardwareWatchdog

    @Test func hardwareWatchdogEvaluatesNormalState() {
        let decision = HardwareWatchdog.evaluateInferenceSafety()
        // На обычной машине при нормальном состоянии инференс должен быть разрешен
        // либо содержать понятную причину отказа
        switch decision {
        case .allowed:
            #expect(true)
        case .restricted(let reason):
            #expect(!reason.isEmpty)
        }
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
        #expect(catalog.contains { $0.id == "qwen_0.5b" })
    }

    @Test func slmModelPathCalculationIsClean() {
        let model = SLMModelStore.catalog[0]
        let path = SLMModelStore.shared.localFileURL(for: model)
        #expect(path.path.contains("Golosok"))
        #expect(path.path.contains("models"))
        #expect(path.lastPathComponent == model.fileName)
    }

    // MARK: - LocalSynthServiceClient fallback

    @Test func localSynthClientFallsBackGracefullyWithoutDaemon() async {
        let client = LocalSynthServiceClient.shared
        // Запрос к несуществующему демону должен безопасно вернуть ошибку/nil без крэша
        let result = await client.synthesize(
            transcript: "Тестовая надиктованная фраза",
            stylePrompt: "Очисти от мусора"
        )
        // Если сервис не запущен, результат nil — и система делает fallback на Этап 1
        #expect(result == nil || !result!.isEmpty)
    }
}

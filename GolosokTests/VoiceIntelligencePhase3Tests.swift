//
//  VoiceIntelligencePhase3Tests.swift
//  GolosokTests
//

import Testing
import Foundation
@testable import Golosok

extension SharedSettingsSuites {
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

        // MARK: - LocalSynthServiceClient fallback

        @Test func localSynthClientFallsBackGracefullyWithoutDaemon() async {
            let client = LocalSynthServiceClient.shared
            client.mockService = nil
            let originalCLI = client.isCLIEnabled
            client.isCLIEnabled = false
            defer { client.isCLIEnabled = originalCLI }

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

            let result = await ThoughtSynthesizer.shared.clean(
                "эээ ну короче тестирование локального отката",
                level: .clean, targetBundleId: nil, firedSpellings: [], language: .ru
            )
            #expect(result.fallback != nil, "При отказе локального демона фреймворк обязан сообщать о fallback")
            #expect(!result.text.isEmpty)
            #expect(!result.text.contains("эээ"))
        }

        @Test func anthropicConfigDetectionAndMessageFormatting() {
            let anthropicConfig = AIProviderConfig(
                baseURL: "https://api.anthropic.com/v1",
                apiKey: "sk-ant-test-key",
                model: "claude-3-5-haiku-20241022",
                providerID: "anthropic"
            )
            #expect(anthropicConfig.isAnthropic == true)

            let openAIConfig = AIProviderConfig(
                baseURL: "https://api.openai.com/v1",
                apiKey: "sk-test",
                model: "gpt-4o-mini",
                providerID: "openai"
            )
            #expect(openAIConfig.isAnthropic == false)

            let proxyConfig = AIProviderConfig(
                baseURL: "https://my-proxy.com/v1",
                apiKey: "sk-test",
                model: "claude-3-5-haiku",
                providerID: "anthropic"
            )
            #expect(proxyConfig.isAnthropic == true)
        }

    }
}

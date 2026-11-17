import Testing
import Foundation
@testable import Tranq

/// Рекомендуемая модель по памяти Mac: класс 8 — Gemma 4 E2B, класс 16 — Gemma 4 E4B.
struct SLMRecommendationTests {
    private let gib: UInt64 = 1_073_741_824

    @Test func memoryClassThreshold() {
        #expect(SLMRecommendation.memoryClass(physicalMemory: 8 * gib) == 8)
        #expect(SLMRecommendation.memoryClass(physicalMemory: 16 * gib - 300 * 1_048_576) == 16)
    }

    @Test func recommendationByMemory() {
        #expect(SLMRecommendation.recommendedModelID(physicalMemory: 8 * gib) == "gemma_4_e2b")
        #expect(SLMRecommendation.recommendedModelID(physicalMemory: 32 * gib) == "gemma_4_e4b_qat")
    }

    @Test func recommendedModelsMatchTheirClass() {
        let small = SLMModelStore.catalog.first { $0.id == SLMRecommendation.smallID }
        let large = SLMModelStore.catalog.first { $0.id == SLMRecommendation.largeID }
        #expect(small?.memoryClassGB == 8)
        #expect(large?.memoryClassGB == 16)
    }

    @Test func pickerLabels() {
        let large = SLMModelStore.catalog.first { $0.id == "gemma_4_e4b_qat" }!
        let spare = SLMModelStore.catalog.first { $0.id == "tlite_2.1" }!
        #expect(SLMRecommendation.pickerLabel(for: large, physicalMemory: 32 * gib).hasSuffix(String(localized: "Рекомендуем")))
        #expect(SLMRecommendation.pickerLabel(for: spare, physicalMemory: 32 * gib) == spare.name)
        #expect(SLMRecommendation.pickerLabel(for: large, physicalMemory: 8 * gib).hasSuffix(String(localized: "Нужно 16 ГБ")))
    }
}

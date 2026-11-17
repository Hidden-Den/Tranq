import Testing
import Foundation
@testable import Tranq

/// Каталог локальных моделей по замеру 17 ноября 2026, см. docs/eval-local-models-2026-11.md.
struct SLMCatalogTests {

    private let retiredIDs = ["vikhr_0.5b", "vikhr_1.5b", "qvikhr_3_4b", "qwen_3.5_0.8b", "qwen_3.5_2b", "llama_3.2_1b"]

    @Test func catalogMatchesDecision() {
        #expect(Set(SLMModelStore.catalog.map(\.id)) == ["gemma_4_e4b_qat", "tlite_2.1", "gemma_4_e2b"])
    }

    @Test func retiredIDsFallBackToSmallRecommendation() {
        for id in retiredIDs + ["qwen_0.5b", "qwen_1.5b", "qwen_3.5_1.5b"] {
            #expect(SLMModelStore.shared.model(named: id)?.id == SLMRecommendation.smallID)
        }
    }

    @Test func retiredFilesSelectsOnlyRetiredNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["QVikhr-3-4B-Instruction-Q4_K_M.gguf", "gemma-4-E2B-it-Q4_K_M.gguf", "notes.txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        #expect(SLMModelStore.retiredFiles(in: dir).map(\.lastPathComponent) == ["QVikhr-3-4B-Instruction-Q4_K_M.gguf"])
    }

    @Test func retiredNamesNeverOverlapCatalog() {
        #expect(Set(SLMModelStore.catalog.map(\.fileName)).isDisjoint(with: SLMModelStore.retiredFileNames))
    }

    @Test func measuredModelsRequireServer() {
        for id in ["gemma_4_e4b_qat", "tlite_2.1", "gemma_4_e2b"] {
            #expect(SLMModelStore.catalog.first { $0.id == id }?.requiresServer == true)
        }
    }

    @Test func memoryClassesAreEightOrSixteen() {
        for model in SLMModelStore.catalog { #expect([8, 16].contains(model.memoryClassGB)) }
        #expect(SLMModelStore.catalog.first { $0.id == "gemma_4_e4b_qat" }?.memoryClassGB == 16)
        #expect(SLMModelStore.catalog.first { $0.id == "gemma_4_e2b" }?.memoryClassGB == 8)
    }

    @Test func descriptionsFitCopyRules() {
        for model in SLMModelStore.catalog {
            #expect(model.description.split(separator: " ").count < 8)
            #expect(!model.description.contains("("))
        }
    }

    @Test func cliFallbackSkippedForServerOnlyModels() {
        let client = LocalSynthServiceClient.shared
        let model = SLMModelStore.catalog.first { $0.id == "gemma_4_e4b_qat" }!
        #expect(client.allowsCLIFallback(modelPath: "/tmp/\(model.fileName)") == false)
        #expect(client.allowsCLIFallback(modelPath: "/tmp/QVikhr-2.5-1.5B-Instruct-SMPO-Q4_K_M.gguf") == true)
    }
}

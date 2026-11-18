import Testing
import Foundation
@testable import Tranq

/// Запись словаря от агента: источник `mcp`, список вариантов агента в чужих записях и откат.
/// Каждый тест работает с отдельной временной папкой и своим доменом UserDefaults.
@MainActor
final class DictionaryAgentWriteTests {
    private let directory: URL
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "dictionary-agent-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> DictionaryStore {
        DictionaryStore(
            directory: directory, defaults: defaults, packsBundle: .main,
            checker: SetCommonWordChecker([:]), packs: []
        )
    }

    private func entry(_ store: DictionaryStore, _ spelling: String) -> DictionaryEntry? {
        store.userEntries.first { $0.spelling.lowercased() == spelling.lowercased() }
    }

    @Test func новоеСловоПолучаетИсточникMCP() {
        let store = makeStore()
        let result = store.addFromAgent([AgentWord(spelling: "Kubernetes", variants: [.ru: ["кубер"]], forceCase: false)])

        #expect(result.added == ["Kubernetes"])
        #expect(result.skipped.isEmpty)
        #expect(entry(store, "Kubernetes")?.source == .mcp)
        #expect(entry(store, "Kubernetes")?.variants[.ru] == ["кубер"])
        #expect(store.agentWordCount == 1)
        #expect(defaults.stringArray(forKey: "dictionary.mcpVariants") ?? [] == [])
    }

    @Test func вариантыАгентаДописываютсяВРучнуюЗаписьИОткатСнимаетТолькоИх() {
        let store = makeStore()
        let human = store.addEntry(spelling: "арипипразол", variants: [.ru: ["арипипразолом"]], source: .manual)
        #expect(store.agentWordCount == 0)

        var notified = 0
        let token = store.objectWillChange.sink { notified += 1 }
        let result = store.addFromAgent([
            AgentWord(spelling: "Арипипразол", variants: [.ru: ["арипипразолом", "абилифай", "арип"]], forceCase: false),
        ])
        token.cancel()

        #expect(result.added == ["Арипипразол"])
        #expect(notified > 0)
        #expect(store.userEntries.count == 1)
        #expect(entry(store, "арипипразол")?.source == .manual)
        #expect(entry(store, "арипипразол")?.variants[.ru] == ["арипипразолом", "абилифай", "арип"])
        #expect(defaults.stringArray(forKey: "dictionary.mcpVariants") == [
            "\(human.id.uuidString)/ru/абилифай", "\(human.id.uuidString)/ru/арип",
        ].sorted())
        #expect(store.agentWordCount == 1)

        store.revertAgentChanges()

        let reverted = entry(store, "арипипразол")
        #expect(reverted?.id == human.id)
        #expect(reverted?.source == .manual)
        #expect(reverted?.variants[.ru] == ["арипипразолом"])
        #expect(defaults.stringArray(forKey: "dictionary.mcpVariants") ?? [] == [])
        #expect(store.agentWordCount == 0)
    }

    @Test func мусорныеСловаОтбрасываютсяОстальныеПроходят() {
        let store = makeStore()
        let result = store.addFromAgent([
            AgentWord(spelling: "", variants: [:], forceCase: false),
            AgentWord(spelling: "   ", variants: [:], forceCase: false),
            AgentWord(spelling: "Slack", variants: [.ru: ["слак"]], forceCase: false),
            AgentWord(spelling: "slack", variants: [.ru: ["слэк"]], forceCase: false),
            AgentWord(spelling: "Jira", variants: [.ru: ["JIRA"]], forceCase: false),
            AgentWord(spelling: "Figma", variants: [.ru: ["ф"]], forceCase: false),
            AgentWord(spelling: "Notion", variants: [.ru: ["ноушн"]], forceCase: true),
        ])

        #expect(result.added == ["Slack", "Notion"])
        #expect(Set(result.skipped.keys) == ["", "   ", "slack", "Jira", "Figma"])
        #expect(result.skipped.values.allSatisfy { !$0.isEmpty })
        #expect(store.userEntries.map(\.spelling) == ["Slack", "Notion"])
        #expect(entry(store, "Slack")?.variants[.ru] == ["слак"])
        #expect(entry(store, "Notion")?.forceCase == true)
    }

    @Test func удалениеБезПолногоДоступаНеТрогаетРучныеСлова() {
        let store = makeStore()
        store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
        store.addEntry(spelling: "Grafana", variants: [.ru: ["графана"]], source: .learned)
        store.addFromAgent([AgentWord(spelling: "Terraform", variants: [.ru: ["терраформ"]], forceCase: false)])

        let result = store.removeFromAgent(spellings: ["kubernetes", "Grafana", "terraform", "Ansible"], fullAccess: false)

        #expect(result.added == ["terraform"])
        #expect(Set(result.skipped.keys) == ["kubernetes", "Grafana", "Ansible"])
        #expect(result.skipped.values.allSatisfy { !$0.isEmpty })
        #expect(Set(store.userEntries.map(\.spelling)) == ["Kubernetes", "Grafana"])
    }

    @Test func удалениеСПолнымДоступомСнимаетРучноеСлово() {
        let store = makeStore()
        store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
        store.addEntry(spelling: "Grafana", variants: [.ru: ["графана"]], source: .learned)

        let result = store.removeFromAgent(spellings: ["kubernetes", "Grafana"], fullAccess: true)

        #expect(result.added == ["kubernetes", "Grafana"])
        #expect(result.skipped.isEmpty)
        #expect(store.userEntries.isEmpty)
    }

    @Test func откатПослеТогоКакЧеловекУдалилЗаписьНеПадает() {
        let store = makeStore()
        let gone = store.addEntry(spelling: "Kubernetes", variants: [.ru: ["кубер"]], source: .manual)
        let kept = store.addEntry(spelling: "Grafana", variants: [.ru: ["графана"]], source: .learned)
        store.addFromAgent([
            AgentWord(spelling: "Kubernetes", variants: [.ru: ["кубернетес"]], forceCase: true),
            AgentWord(spelling: "Grafana", variants: [.ru: ["графаной", "графане"]], forceCase: false),
            AgentWord(spelling: "Terraform", variants: [.ru: ["терраформ"]], forceCase: false),
        ])
        #expect(store.agentWordCount == 3)

        store.removeEntry(id: gone.id)
        store.removeVariant("графаной", language: .ru, fromEntryKey: "user/\(kept.id.uuidString)")

        store.revertAgentChanges()

        #expect(store.userEntries.map(\.spelling) == ["Grafana"])
        #expect(entry(store, "Grafana")?.variants[.ru] == ["графана"])
        #expect(entry(store, "Grafana")?.source == .learned)
        #expect(defaults.stringArray(forKey: "dictionary.mcpVariants") ?? [] == [])
        #expect(store.agentWordCount == 0)
    }

    @Test func откатСнимаетЖёсткийРегистрТолькоЕслиЕгоПоставилАгент() {
        let store = makeStore()
        store.addEntry(spelling: "GitHub", variants: [.ru: ["гитхаб"]], source: .manual, forceCase: true)
        let plain = store.addEntry(spelling: "Slack", variants: [.ru: ["слак"]], source: .manual)
        store.addFromAgent([
            AgentWord(spelling: "github", variants: [:], forceCase: true),
            AgentWord(spelling: "slack", variants: [:], forceCase: true),
        ])

        #expect(defaults.stringArray(forKey: "dictionary.mcpVariants") == ["\(plain.id.uuidString)/forceCase"])
        #expect(entry(store, "Slack")?.forceCase == true)
        #expect(store.agentWordCount == 1)

        store.revertAgentChanges()

        #expect(entry(store, "GitHub")?.forceCase == true)
        #expect(entry(store, "Slack")?.forceCase == false)
        #expect(entry(store, "Slack")?.variants[.ru] == ["слак"])
        #expect(store.agentWordCount == 0)
    }
}

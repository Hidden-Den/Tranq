import Testing
import Foundation
import Combine
@testable import Tranq

/// Замок истории и нейронки: пока история заперта, `dictations` отказывает ошибкой протокола,
/// остальные команды работают, а лог не получает текст расшифровок.
@MainActor
final class MCPLockTests {
    private let suiteName = "mcp-lock-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let directory: URL

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPLockTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeAccess(historyAccess: Bool = true, locked: Bool = true) -> MCPAccess {
        let access = MCPAccess(defaults: defaults)
        access.enabled = true
        access.historyAccess = historyAccess
        access.historyLocked = locked
        return access
    }

    private func denial(_ access: MCPAccess, _ command: MCPCommandName) -> String? {
        if case .deny(let text) = access.verdict(for: command, disablingPack: false) { return text }
        return nil
    }

    private func makeDoor(_ access: MCPAccess) -> (MCPDoor, HistoryStore) {
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        let history = HistoryStore(directory: historyDirectory, saveDelay: 10)
        history.insert(TranscriptionItem(date: "д", text: "итог", duration: "0:05", spokenText: "сказано"))
        let dictionary = DictionaryStore(
            directory: directory.appendingPathComponent("dict", isDirectory: true), defaults: defaults,
            packsBundle: .main, checker: SetCommonWordChecker([:]), packs: []
        )
        return (MCPDoor(dictionary: dictionary, history: history, access: access, language: .ru), history)
    }

    private func parse(_ answer: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - Шлюз

    @Test func dictationsDeniedWhileLocked() {
        let access = makeAccess()
        #expect(denial(access, .dictations) == String(localized: "История заперта. Разблокируйте её в Tranq."))
    }

    @Test func denialIsErrorNotEmptyList() {
        let (door, history) = makeDoor(makeAccess())
        // Заперта настоящая история: список пуст, но дверь обязана ответить ошибкой, а не пустым списком.
        history.applyLockState(.locked)
        let answer = parse(door.handle(line: "{\"cmd\":\"dictations\"}"))
        #expect(answer["ok"] as? Bool == false)
        #expect(answer["data"] == nil)
        #expect(answer["error"] as? String == String(localized: "История заперта. Разблокируйте её в Tranq."))
    }

    @Test func toolsStillListedWhileLocked() {
        let access = makeAccess()
        // Список инструментов не меняется: команда на месте, остальные работают.
        #expect(MCPCommandName.allCases.contains(.dictations))
        for command in MCPCommandName.allCases where command != .dictations {
            #expect(denial(access, command) == nil, "команда \(command.rawValue) остаётся доступной")
        }
        #expect(access.historyAccess == true, "выключатель истории замок не трогает")
    }

    @Test func wordsStillAllowedWhileLocked() {
        let (door, _) = makeDoor(makeAccess())
        let answer = parse(door.handle(line: "{\"cmd\":\"words\"}"))
        #expect(answer["ok"] as? Bool == true)
        #expect(answer["data"] is [Any])
    }

    @Test func dictationsAllowedAfterUnlock() {
        let access = makeAccess()
        #expect(denial(access, .dictations) != nil)
        access.historyLocked = false
        #expect(denial(access, .dictations) == nil)
    }

    @Test func historyOffKeepsOldDenialWhenLocked() {
        let locked = makeAccess(historyAccess: false, locked: true)
        let unlocked = makeAccess(historyAccess: false, locked: false)
        let text = denial(locked, .dictations)
        #expect(text != nil)
        #expect(text == denial(unlocked, .dictations), "замок не выдаёт себя, когда доступ к истории выключен")
        #expect(text != String(localized: "История заперта. Разблокируйте её в Tranq."))
    }

    @Test func lockedByDefaultIsFalse() {
        #expect(MCPAccess(defaults: defaults).historyLocked == false)
    }

    // MARK: - Состояние замка

    @Test func stateMapsToHistoryLocked() {
        let access = makeAccess(locked: false)
        let states = CurrentValueSubject<HistoryLockState, Never>(.locked)
        let binding = access.bindHistoryLock(to: states.eraseToAnyPublisher())
        #expect(access.historyLocked == true, "первое значение применяется сразу")
        let expected: [(HistoryLockState, Bool)] = [
            (.unlocked, false), (.keyUnavailable, true), (.off, false), (.locked, true),
        ]
        for (state, locked) in expected {
            states.send(state)
            #expect(access.historyLocked == locked)
        }
        binding.cancel()
        states.send(.unlocked)
        #expect(access.historyLocked == true, "после отмены подписки флаг не меняется")
    }

    @Test func coordinatorStateFlipsHistoryLocked() async {
        let key = TestHistoryKey()
        try? key.create()
        let store = HistoryStore(directory: directory, saveDelay: 0)
        let journal = TranscriptJournal(directory: directory)
        let clock = TestClock()
        let coordinator = HistoryLockCoordinator(
            enabled: true, store: store, journal: journal, key: key, presence: TestPresence(),
            directory: directory, erase: { [] }, resetSession: {}, now: { clock.date })
        defer { store.flush(); journal.flush() }

        let access = makeAccess(locked: false)
        let binding = access.bindHistoryLock(to: coordinator.$state.eraseToAnyPublisher())
        #expect(coordinator.state == .locked)
        #expect(access.historyLocked == true, "флаг выставлен до первого запроса")

        await coordinator.unlock()
        #expect(coordinator.state == .unlocked)
        #expect(access.historyLocked == false)

        coordinator.noteSystemWillSleep()
        #expect(coordinator.state == .locked)
        #expect(access.historyLocked == true)
        binding.cancel()
    }

    // MARK: - Лог

    private func logLines(_ logger: AppLogger) -> String {
        logger.flush()
        guard let url = logger.logFileURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func loggerOmitsTranscriptTextWhenLockEnabled() {
        let logger = AppLogger(directory: directory)
        let text = "секретная фраза диктовки"
        let id = UUID()
        logger.redactTranscripts = true
        logger.info("Test", "Итог", details: "Финальный текст: \(logger.transcript(text, id: id))")
        let written = logLines(logger)
        #expect(!written.contains("секретная"))
        #expect(written.contains("\(text.count) симв."))
        #expect(written.contains(id.uuidString))
    }

    @Test func loggerKeepsTextWhenLockOff() {
        let logger = AppLogger(directory: directory)
        #expect(logger.redactTranscripts == false)
        #expect(logger.transcript("привет мир", id: UUID()) == "«привет мир»")
        logger.info("Test", "Итог", details: "Финальный текст: \(logger.transcript("привет мир"))")
        #expect(logLines(logger).contains("привет мир"))
        logger.redactTranscripts = true
        #expect(logger.transcript("привет мир") == "10 симв.")
        #expect(logger.transcript("привет мир", quoted: false) == "10 симв.")
        logger.redactTranscripts = false
        #expect(logger.transcript("привет мир") == "«привет мир»")
        #expect(logger.transcript("привет мир", quoted: false) == "привет мир")
    }

    @Test func loggerRedactionFollowsLockState() {
        let logger = AppLogger(directory: directory)
        let states = CurrentValueSubject<HistoryLockState, Never>(.off)
        let binding = logger.bindTranscriptRedaction(to: states.eraseToAnyPublisher())
        #expect(logger.redactTranscripts == false)
        for state in [HistoryLockState.locked, .unlocked, .keyUnavailable] {
            states.send(state)
            #expect(logger.redactTranscripts == true, "замок включён, текст не пишется: \(state)")
        }
        states.send(.off)
        #expect(logger.redactTranscripts == false)
        binding.cancel()
    }
}

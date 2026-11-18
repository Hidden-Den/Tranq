import Testing
import Foundation
@testable import Tranq

/// Уровни доступа нейронок: три выключателя, все по умолчанию выключены.
/// Тексты отказов зависят от языка приложения, поэтому тесты проверяют только отказ и непустой текст.
final class MCPAccessTests {
    private let suiteName = "mcp-access-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeAccess(enabled: Bool = false, fullAccess: Bool = false, historyAccess: Bool = false) -> MCPAccess {
        let access = MCPAccess(defaults: defaults)
        access.enabled = enabled
        access.fullAccess = fullAccess
        access.historyAccess = historyAccess
        return access
    }

    /// Текст отказа или `nil`, если команда разрешена.
    private func denial(_ access: MCPAccess, _ command: MCPCommandName, disablingPack: Bool = false) -> String? {
        if case .deny(let text) = access.verdict(for: command, disablingPack: disablingPack) { return text }
        return nil
    }

    @Test func поУмолчаниюВсёВыключено() {
        let access = MCPAccess(defaults: defaults)
        #expect(access.enabled == false)
        #expect(access.fullAccess == false)
        #expect(access.historyAccess == false)
    }

    @Test func безДоступаЛюбаяКомандаОтклоняется() {
        // Даже включённые полный доступ и история не открывают дверь, пока она закрыта.
        let access = makeAccess(enabled: false, fullAccess: true, historyAccess: true)
        for command in MCPCommandName.allCases {
            for disabling in [false, true] {
                let text = denial(access, command, disablingPack: disabling)
                #expect(text?.isEmpty == false, "команда \(command.rawValue) должна быть отклонена с текстом")
            }
        }
    }

    @Test func отказПриВыключенномДоступеОдинаковДляВсехКоманд() {
        let access = makeAccess()
        let texts = Set(MCPCommandName.allCases.compactMap { denial(access, $0) })
        #expect(texts.count == 1)
    }

    @Test func историяТребуетСвоегоРазрешения() {
        let access = makeAccess(enabled: true, fullAccess: true)
        let withoutHistory = denial(access, .dictations)
        #expect(withoutHistory?.isEmpty == false)
        // Причина другая, чем у закрытой двери.
        #expect(withoutHistory != denial(makeAccess(), .dictations))

        access.historyAccess = true
        #expect(access.verdict(for: .dictations, disablingPack: false) == .allow)
    }

    @Test func историяНеНужнаДругимКомандам() {
        let access = makeAccess(enabled: true, fullAccess: true)
        for command in MCPCommandName.allCases where command != .dictations {
            #expect(access.verdict(for: command, disablingPack: false) == .allow, "команда \(command.rawValue)")
        }
    }

    @Test func выключениеНабораТребуетПолногоДоступа() {
        let access = makeAccess(enabled: true, historyAccess: true)
        let text = denial(access, .setPack, disablingPack: true)
        #expect(text?.isEmpty == false)

        access.fullAccess = true
        #expect(access.verdict(for: .setPack, disablingPack: true) == .allow)
    }

    @Test func удалениеСловДоступноБезПолногоДоступа() {
        // Без полного доступа агент всё равно вправе убрать слова, которые добавил сам.
        // Различие между своими и чужими словами проводит хранилище, не шлюз.
        let access = makeAccess(enabled: true, fullAccess: false)
        #expect(access.verdict(for: .removeWords, disablingPack: false) == .allow)

        access.fullAccess = true
        #expect(access.verdict(for: .removeWords, disablingPack: false) == .allow)

        access.enabled = false
        #expect(denial(access, .removeWords)?.isEmpty == false)
    }

    @Test func отказПолногоДоступаОтличаетсяОтОтказаИстории() {
        let access = makeAccess(enabled: true)
        let full = denial(access, .setPack, disablingPack: true)
        let history = denial(access, .dictations)
        #expect(full != nil && history != nil)
        #expect(full != history)
        #expect(full != denial(makeAccess(), .setPack, disablingPack: true))
    }

    @Test func включениеНабораРазрешеноБезПолногоДоступа() {
        let access = makeAccess(enabled: true)
        #expect(access.verdict(for: .setPack, disablingPack: false) == .allow)
    }

    @Test func остальныеКомандыРазрешеныПриВключённомДоступе() {
        let access = makeAccess(enabled: true)
        for command in [MCPCommandName.packs, .words, .addWords, .revertAgentWords, .removeWords] {
            #expect(access.verdict(for: command, disablingPack: false) == .allow, "команда \(command.rawValue)")
        }
    }

    @Test func флагиХранятсяПодСвоимиКлючами() {
        let access = MCPAccess(defaults: defaults)
        access.enabled = true
        access.fullAccess = true
        access.historyAccess = true
        #expect(defaults.object(forKey: "mcp.enabled") as? Bool == true)
        #expect(defaults.object(forKey: "mcp.fullAccess") as? Bool == true)
        #expect(defaults.object(forKey: "mcp.historyAccess") as? Bool == true)

        access.fullAccess = false
        #expect(defaults.object(forKey: "mcp.fullAccess") as? Bool == false)
        #expect(defaults.object(forKey: "mcp.enabled") as? Bool == true)
    }

    @Test func флагиЧитаютсяДругимЭкземпляромНаТомЖеНаборе() {
        let first = MCPAccess(defaults: defaults)
        first.enabled = true
        first.historyAccess = true

        let second = MCPAccess(defaults: defaults)
        #expect(second.enabled == true)
        #expect(second.historyAccess == true)
        #expect(second.fullAccess == false)
    }

    // MARK: - Выключение доступа снимает полный доступ и историю

    @Test func выключениеДоступаСбрасываетПолныйДоступИИсторию() {
        let access = MCPAccess(defaults: defaults)
        access.enabled = true
        access.fullAccess = true
        access.historyAccess = true

        access.enabled = false
        #expect(access.fullAccess == false)
        #expect(access.historyAccess == false)
        // Сброс записан в настройки теми же ключами, другой экземпляр на том же наборе читает его.
        #expect(defaults.object(forKey: "mcp.fullAccess") as? Bool == false)
        #expect(defaults.object(forKey: "mcp.historyAccess") as? Bool == false)
        let second = MCPAccess(defaults: defaults)
        #expect(second.enabled == false)
        #expect(second.fullAccess == false)
        #expect(second.historyAccess == false)
    }

    @Test func повторноеВключениеДоступаНеВозвращаетПолныйДоступИИсторию() {
        let access = MCPAccess(defaults: defaults)
        access.enabled = true
        access.fullAccess = true
        access.historyAccess = true
        access.enabled = false

        access.enabled = true
        #expect(access.fullAccess == false)
        #expect(access.historyAccess == false)
        // Права не вернулись и для тех, кто откроет настройки заново.
        let second = MCPAccess(defaults: defaults)
        #expect(second.enabled == true)
        #expect(second.fullAccess == false)
        #expect(second.historyAccess == false)
        // Шлюз тоже видит их выключенными.
        #expect(denial(access, .dictations)?.isEmpty == false)
        #expect(denial(access, .setPack, disablingPack: true)?.isEmpty == false)
    }

    @Test func приВключённомДоступеФлагиВключаютсяПоОтдельностиИХранятся() {
        let access = MCPAccess(defaults: defaults)
        access.enabled = true

        access.fullAccess = true
        #expect(access.fullAccess == true)
        #expect(access.historyAccess == false)
        #expect(MCPAccess(defaults: defaults).fullAccess == true)
        #expect(MCPAccess(defaults: defaults).historyAccess == false)

        access.historyAccess = true
        #expect(access.fullAccess == true)
        #expect(access.historyAccess == true)
        let second = MCPAccess(defaults: defaults)
        #expect(second.enabled == true)
        #expect(second.fullAccess == true)
        #expect(second.historyAccess == true)
    }

    @Test func сбросНеЗапускаетсяПриСозданииЭкземпляра() {
        // Права, записанные при включённом доступе, переживают перезапуск: сброс идёт только от выключения.
        let first = MCPAccess(defaults: defaults)
        first.enabled = true
        first.fullAccess = true
        first.historyAccess = true

        let second = MCPAccess(defaults: defaults)
        #expect(second.enabled == true)
        #expect(second.fullAccess == true)
        #expect(second.historyAccess == true)
    }

    @Test func повторноеВыключениеУжеВыключенногоДоступаНичегоНеМеняет() {
        let access = MCPAccess(defaults: defaults)
        access.enabled = false

        #expect(access.enabled == false)
        #expect(access.fullAccess == false)
        #expect(access.historyAccess == false)
        let second = MCPAccess(defaults: defaults)
        #expect(second.enabled == false)
        #expect(second.fullAccess == false)
        #expect(second.historyAccess == false)
    }

    @Test func чужойНаборНеВлияетНаЭтот() {
        let otherName = "mcp-access-tests-other-\(UUID().uuidString)"
        let other = UserDefaults(suiteName: otherName)!
        defer { other.removePersistentDomain(forName: otherName) }

        MCPAccess(defaults: other).enabled = true
        #expect(MCPAccess(defaults: defaults).enabled == false)
    }
}

//
//  VoiceIntelligenceGoldenDataset.swift
//  GolosokTests
//

import Foundation
@testable import Golosok

public enum GoldenCategory: String, CaseIterable {
    case fillers
    case stutters
    case numbersAndDates
    case questions
    case technicalTerms
    case compoundMixed
}

public struct GoldenSample {
    public let id: String
    public let category: GoldenCategory
    public let rawSpeech: String
    public let expectedNumbers: [String]
    public let isQuestion: Bool
    public let forbiddenFillers: [String]
    public let style: VoiceStyle
    public let targetBundleId: String?

    public init(
        id: String,
        category: GoldenCategory,
        rawSpeech: String,
        expectedNumbers: [String] = [],
        isQuestion: Bool = false,
        forbiddenFillers: [String] = [],
        style: VoiceStyle = .clean,
        targetBundleId: String? = nil
    ) {
        self.id = id
        self.category = category
        self.rawSpeech = rawSpeech
        self.expectedNumbers = expectedNumbers
        self.isQuestion = isQuestion
        self.forbiddenFillers = forbiddenFillers
        self.style = style
        self.targetBundleId = targetBundleId
    }
}

public struct VoiceIntelligenceGoldenDataset {

    /// Набор из 320+ структурированных примеров русской речи
    public static let allSamples: [GoldenSample] = {
        var samples: [GoldenSample] = []
        samples.append(contentsOf: generateFillerSamples())
        samples.append(contentsOf: generateStutterSamples())
        samples.append(contentsOf: generateNumberAndDateSamples())
        samples.append(contentsOf: generateQuestionSamples())
        samples.append(contentsOf: generateTechnicalTermSamples())
        samples.append(contentsOf: generateCompoundMixedSamples())
        return samples
    }()

    // MARK: - 1. Звуковые паразиты и заминки (50+ примеров)
    private static func generateFillerSamples() -> [GoldenSample] {
        let fillers = ["эээ", "нууу", "хм", "хмм", "ээ", "ааа", "ммм", "uh", "um", "э-э", "а-а", "м-м"]
        let contexts = [
            "надо отправить отчет руководству",
            "мы закончили тестирование новой версии",
            "проверь статус сборки проекта в Xcode",
            "давай назначим созвон на завтра",
            "клиент просил обновить смету"
        ]

        var list: [GoldenSample] = []
        var index = 1
        for filler in fillers {
            for ctx in contexts {
                let text = "\(filler) \(ctx) \(filler)"
                list.append(GoldenSample(
                    id: "filler_\(index)",
                    category: .fillers,
                    rawSpeech: text,
                    forbiddenFillers: [filler]
                ))
                index += 1
            }
        }
        return list
    }

    // MARK: - 2. Заикания и повторы слов (50+ примеров)
    private static func generateStutterSamples() -> [GoldenSample] {
        let stutterPairs = [
            "я я", "мы мы", "в в", "на на", "и и",
            "надо надо", "нужно нужно", "будет будет", "это это", "тут тут"
        ]
        let tails = [
            "отправить релиз сегодня до вечера",
            "проверить логи на сервере",
            "созвониться с командой разработки",
            "обновить конфигурацию приложения",
            "добавить модульные тесты для шлюза"
        ]

        var list: [GoldenSample] = []
        var index = 1
        for pair in stutterPairs {
            for tail in tails {
                let text = "\(pair) \(tail)"
                list.append(GoldenSample(
                    id: "stutter_\(index)",
                    category: .stutters,
                    rawSpeech: text
                ))
                index += 1
            }
        }
        return list
    }

    // MARK: - 3. Числа, даты и валюты (60+ примеров)
    private static func generateNumberAndDateSamples() -> [GoldenSample] {
        let numberPhrases: [(raw: String, expected: [String])] = [
            ("Встреча назначена на 14:30", ["14:30"]),
            ("Переведи 2500 рублей на карту", ["2500"]),
            ("Номер заказа 40817810 проверь статус", ["40817810"]),
            ("Стоимость подписки 15 долларов в месяц", ["15"]),
            ("Релиз выйдет 26 мая в 18:00", ["26", "18:00"]),
            ("Температура процессора поднялась до 85 градусов", ["85"]),
            ("В тесте задействовано 128 потоков", ["128"]),
            ("Объем памяти 16 гигабайт", ["16"]),
            ("Версия протокола 1.16", ["1.16"]),
            ("Скидка составляет 20 процентов", ["20"]),
            // Словесные числительные и даты для проверки NumberNormalizer
            ("Встреча назначена на четырнадцать тридцать", ["14:30"]),
            ("Переведи двадцать пять рублей на карту", ["25"]),
            ("Релиз выйдет двадцать шестого мая", ["26 мая"]),
            ("Температура поднялась до пятидесяти градусов", ["50"]),
            ("В тесте задействовано двенадцать потоков", ["12"])
        ]
        let intros = [
            "Пожалуйста зафиксируй:",
            "Срочное напоминание:",
            "Внеси в документ:",
            "Отправь в чат сообщение:",
            "Создай задачу в трекере:",
            "Запиши заметку:"
        ]

        var list: [GoldenSample] = []
        var index = 1
        for (raw, exp) in numberPhrases {
            for intro in intros {
                let full = "\(intro) \(raw)"
                list.append(GoldenSample(
                    id: "num_\(index)",
                    category: .numbersAndDates,
                    rawSpeech: full,
                    expectedNumbers: exp
                ))
                index += 1
            }
        }
        return list
    }

    // MARK: - 4. Вопросы и команды (60+ примеров)
    private static func generateQuestionSamples() -> [GoldenSample] {
        let questions = [
            "Сколько сейчас времени в Токио?",
            "Как настроить локальный Metal инференс?",
            "Почему не проходит авторизация в сервисе?",
            "Где хранится конфигурационный файл настроек?",
            "Когда запланирован следующий релиз?",
            "Зачем мы отключаем reasoning в облаке?",
            "Что такое детерминированный валидатор?",
            "Кто отвечает за деплой на сервер?",
            "Успеем ли мы выпустить хотфикс сегодня?",
            "Какой порог памяти установлен для выгрузки?"
        ]
        let variations = [
            "",
            "эээ подскажи пожалуйста ",
            "нууу слушай ",
            "хм интересно ",
            "скажи мне ",
            "проверь пожалуйста "
        ]

        var list: [GoldenSample] = []
        var index = 1
        for q in questions {
            for v in variations {
                let full = "\(v)\(q)"
                list.append(GoldenSample(
                    id: "question_\(index)",
                    category: .questions,
                    rawSpeech: full,
                    isQuestion: true
                ))
                index += 1
            }
        }
        return list
    }

    // MARK: - 5. Технические и англоязычные термины (50+ примеров)
    private static func generateTechnicalTermSamples() -> [GoldenSample] {
        let terms = [
            "Golosok", "Docker", "Kubernetes", "Metal", "Apple Silicon",
            "Xcode", "SwiftUI", "OpenRouter", "PostgreSQL", "JSONL"
        ]
        let templates = [
            "Запусти {TERM} контейнер на локальной машине",
            "Настрой архитектуру с использованием {TERM}",
            "В новой версии мы обновили {TERM} модуль",
            "Проверь совместимость с {TERM} фреймворком",
            "Добавь логирование в {TERM} пайплайн"
        ]

        var list: [GoldenSample] = []
        var index = 1
        for term in terms {
            for tpl in templates {
                let full = tpl.replacingOccurrences(of: "{TERM}", with: term)
                list.append(GoldenSample(
                    id: "tech_\(index)",
                    category: .technicalTerms,
                    rawSpeech: full,
                    targetBundleId: "com.microsoft.VSCode"
                ))
                index += 1
            }
        }
        return list
    }

    // MARK: - 6. Комплексные смешанные реплики (50+ примеров)
    private static func generateCompoundMixedSamples() -> [GoldenSample] {
        let templates = [
            "эээ слушай я я думаю надо в 15:30 созвониться по поводу релиза Golosok",
            "нууу переведи 3500 рублей за хостинг Docker сервера",
            "хм а сколько времени займет сборка 128 файлов в Xcode?",
            "эээ почему сервер на порту 8080 не отвечает на запросы?",
            "нууу давай добавим в базу данных 50 новых записей",
            "эээ когда выйдет версия 1.16 с поддержкой Metal ускорения?",
            "хмм мы мы должны отправить 3 отчета клиенту до 19:00",
            "эээ как настроить безопасный буфер в macOS без сохранения в истории?",
            "нууу обнови 4 зависимости в файле Package.swift",
            "эээ сколько памяти потребляет модель Vikhr 1.5B на чипе M3?"
        ]
        let apps = [
            "ru.keepcoder.Telegram",
            "com.tinyspeck.slackmacgap",
            "com.microsoft.VSCode",
            "md.obsidian",
            "com.apple.mail"
        ]

        var list: [GoldenSample] = []
        var index = 1
        for tpl in templates {
            for app in apps {
                let style: VoiceStyle
                switch app {
                case "com.apple.mail":
                    style = .formal
                case "md.obsidian":
                    style = .bullets
                case "com.microsoft.VSCode":
                    style = .prompt
                default:
                    style = .clean
                }

                list.append(GoldenSample(
                    id: "compound_\(index)",
                    category: .compoundMixed,
                    rawSpeech: tpl,
                    isQuestion: tpl.contains("?"),
                    style: style,
                    targetBundleId: app
                ))
                index += 1
            }
        }
        return list
    }
}

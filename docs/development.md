# Tranq изнутри

Технический документ для тех, кто дорабатывает Tranq. Руководство для пользователей — в [README](../README.md), правила участия — в [CONTRIBUTING](../CONTRIBUTING.md).

## Стек

| Часть | Что используется |
| :--- | :--- |
| Платформа | macOS 13.5+, только Apple Silicon |
| Приложение | Swift, SwiftUI, AppKit; проект `Tranq.xcodeproj` с синхронизированными группами |
| Распознавание | GigaAM v3 RNN-T через [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), Swift-пакет `Packages/TranscribeCppBinary`; Whisper через `whisper-cli` |
| Локальная очистка | `llama-server` из llama.cpp, модели GGUF с Hugging Face |
| Внешняя очистка | HTTP API в формате OpenAI или Anthropic |
| Горячие клавиши | Carbon Event Manager для сочетаний, `CGEventTap` для модификаторов и `Fn` |
| Вставка | буфер обмена и синтетический `⌘ V` через Accessibility |
| MCP | помощник `tranq-mcp` на Go 1.27, Unix-сокет до приложения |
| Шифрование истории | CryptoKit, ключ в Secure Enclave или связке ключей, `LocalAuthentication` |
| Тесты | Swift Testing, `go test` |

## Путь диктовки

```
Микрофон ─► AudioCapture ─► TranscriptionPipeline
                              │
                              ├─ 1. Распознавание: GigaAMEngine или WhisperCLIEngine,
                              │     длинная запись режется по самой тихой точке
                              ├─ 2. Этап A без модели: TextFormatter
                              ├─ 3. Словарь: DictionaryStage, до модели
                              ├─ 4. Очистка: ThoughtSynthesizer — DisfluencyPrefilter,
                              │     нарезка TranscriptChunker, запрос к локальному
                              │     LocalLLMServer или внешнему API через ChatRequestBuilder
                              ├─ 5. Проверка: GroundingValidator и NumberNormalizer,
                              │     при отказе откат на этап A
                              └─ 6. Повторный проход словаря по ответу модели
                              │
                              ▼
               InsertionService ─► активное окно; HistoryStore ─► заметка
```

- **Уровень очистки** выбирает `CleanupLevelResolver`: без правила — чистая речь, с правилом приложения или сайта — переписывание в тоне правила. Контекст, то есть приложение и адрес вкладки, снимает `DictationContextCapture` через Accessibility и `BrowserURLReader`.
- **Инструкция модели** по умолчанию лежит в `VoiceIntelligenceSettings.defaultCustomPrompt`. Тоны правил — в `Tranq/Rules/DictationRule.swift`.
- **Сроки ответа** модели: ожидание начала ответа, пауза внутри ответа и общий потолок от длины речи. Оборванное соединение получает одну повторную попытку.
- **Журнал** `TranscriptJournal` хранит последние диктовки для `⌥ ⌘ Z` и для выгрузки в замер качества.

## Структура репозитория

| Путь | Что там |
| :--- | :--- |
| `Tranq/` | код приложения |
| `Tranq/Dictionary/` | словарь: хранилище, индекс, фонетика, нечёткий поиск, обучение на правках, запись от агентов |
| `Tranq/Dictionaries/` | встроенные наборы словаря в JSON |
| `Tranq/Rules/` | правила приложений и сайтов, тоны, снятие контекста |
| `Tranq/Privacy/` | замок истории: ключи, шифрование, хранилище, миграция, выгрузка |
| `Tranq/MCP/` | сторона приложения для `tranq-mcp`: сокет, уровни доступа, сниппеты конфига |
| `Tranq/Settings/` | разделы настроек |
| `Tranq/Localizable.xcstrings` | строки интерфейса, русский и английский |
| `TranqTests/` | unit-тесты, корпус словаря, замер качества `Eval/` |
| `mcp/` | Go-модуль `tranq-mcp`, зависимости в `mcp/vendor` |
| `Packages/TranscribeCppBinary/` | бинарный Swift-пакет transcribe.cpp |
| `Brand/` | исходники знаков бренда и скрипт их извлечения из Knewave |
| `scripts/` | зависимости, сборка dmg, проверка имени, замер качества |
| `docs/` | документация |

## Сборка

Нужны Xcode 26 или новее и Go 1.27 или новее.

```bash
git clone https://github.com/Hidden-Den/Tranq.git
cd Tranq
brew install go
scripts/fetch-deps.sh
open Tranq.xcodeproj
```

- `scripts/fetch-deps.sh` скачивает `gigaam.gguf` в `Tranq/` и `llama-server` в `Vendor/llama/`. Версии и SHA-256 зафиксированы в скрипте, скачанное кэшируется в `build/deps-cache`.
- Фаза сборки Xcode вызывает `scripts/build-tranq-mcp.sh`, собирает `tranq-mcp` из vendor без сети и кладёт рядом с исполняемым файлом. Без Go сборка падает.
- Без модели и `llama-server` проект тоже собирается, но распознавание и локальная очистка работать не будут.

### Релизный dmg

```bash
scripts/build-dmg.sh
```

Собирает Release для arm64 с ad-hoc подписью и hardened runtime, проверяет подпись приложения и `tranq-mcp`, наличие модели и `llama-server` в бандле и совпадение версий. Результат — `build/Tranq.dmg`. Нотаризации нет, пользователям нужен `xattr -cr`.

## Тесты

```bash
xcodebuild test -project Tranq.xcodeproj -scheme Tranq \
  -destination 'platform=macOS' -only-testing:TranqTests
```

```bash
cd mcp && go vet ./... && go test -mod=vendor -race ./...
```

```bash
bash scripts/check-brand.sh
```

- Тесты, которым нужна модель GigaAM, без неё пропускаются.
- Наборы тестов, которые меняют общие настройки, выполняются последовательно, см. `TranqTests/SharedSettingsSuites.swift`.
- `TranqTests/DictionaryCorpus` — корпус для словаря: что должно исправляться и что трогать нельзя.

CI в `.github/workflows/ci.yml` прогоняет проверку имени, `gofmt`, `go vet`, тесты Go и unit-тесты Xcode на каждый пуш в `main` и на пулл-реквесты. Запуски от внешних участников ждут одобрения.

## Замер качества очистки

Промпты и проверку ответа меняют по цифрам, а не на глаз. Набор из 100 фраз с эталонами и прогон через любую модель описаны в [eval.md](eval.md), результаты по локальным моделям — в [eval-local-models-2026-11.md](eval-local-models-2026-11.md).

Личные диктовки в репозиторий не кладутся, набор из них хранится вне его.

## MCP

`tranq-mcp` — отдельный процесс, который запускает MCP-клиент. Он говорит с клиентом по MCP через stdin и stdout, а с приложением — построчным JSON через Unix-сокет `~/Library/Application Support/Tranq/mcp.sock`. Каждая команда проходит проверку уровня доступа в `MCPAccess`. Протокол сокета: [mcp/PROTOCOL.md](../mcp/PROTOCOL.md). Описание для пользователей: [mcp.md](mcp.md).

## Данные на диске

| Путь | Что |
| :--- | :--- |
| `~/Library/Application Support/Tranq/Notes` | заметки истории |
| `~/Library/Application Support/Tranq/Audio` | записи голоса |
| `~/Library/Application Support/Tranq/Logs` | лог приложения |
| `~/Library/Application Support/Tranq/dictionary.json` | словарь пользователя |
| `~/Library/Application Support/Tranq/models` | скачанные модели |
| `~/Library/Preferences/nuter.Tranq.plist` | настройки, в том числе ключ API |

Ключ API хранится в `UserDefaults` через `KeyStore`, без связки ключей, чтобы macOS не спрашивала доступ при каждом запуске. Перенос в Keychain — открытая задача.

## Правила кода и интерфейса

- Интерфейс: монохром, Inter через `Font.ui`, Knewave только для названия, подписи в одно-два слова, без скобок. Подробнее в [CONTRIBUTING](../CONTRIBUTING.md#правила-интерфейса).
- `Localizable.xcstrings` правится в Xcode или скриптом, который сохраняет форматирование Xcode. Обычный `json.dump` его ломает.
- Имя только `Tranq`, проверяется `scripts/check-brand.sh`.

## Релиз

1. Поднять `MARKETING_VERSION` в `Tranq.xcodeproj/project.pbxproj`: `X.Y` для новых возможностей, `X.Y.Z` для исправлений.
2. Дописать [CHANGELOG](../CHANGELOG.md).
3. `scripts/build-dmg.sh`.
4. Тег `vX.Y.Z` и релиз на GitHub с `build/Tranq.dmg` и заметками на русском.

Приложение проверяет `https://api.github.com/repos/Hidden-Den/Tranq/releases/latest` раз в четыре часа, поэтому релиз должен быть отмечен как последний.

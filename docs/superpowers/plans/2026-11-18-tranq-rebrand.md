# Tranq: ребрендинг Голоска. План работ

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить Голосок на Tranq целиком: идентификаторы, имя в интерфейсе, шрифты Inter и Knewave, адаптивная иконка с буквой Q, документы, упаковка и репозиторий.

**Architecture:** Переименование идёт механически и проверяется сборкой и тестами. Шрифты подключаются кодом через `CTFontManager`, а не через plist. Все тексты по-прежнему идут через `Font.ui`, меняется только его реализация. Иконка собирается в Icon Composer, буква Q берётся из Knewave как векторный контур.

**Tech Stack:** Swift, SwiftUI, Swift Testing, Xcode 27, Icon Composer, fontTools в отдельном venv вне репозитория, `gh`.

**Spec:** `docs/superpowers/specs/2026-11-18-tranq-rebrand-design.md`

## Global Constraints

- Имя только `Tranq`, латиницей, в тексте без кавычек. Слов «Голосок» и «Golosok» не остаётся нигде, кроме `docs/superpowers/specs` и `docs/superpowers/plans`.
- Фирменный шрифт Knewave, лицензия OFL, только название и буква Q. Шрифт интерфейса Inter, лицензия OFL. Тексты лицензий лежат рядом со шрифтами.
- Монохром, акцентного цвета нет. Палитра и шкала `UITextSize` не меняются, минимум 10 pt.
- В новых пользовательских строках нет круглых, квадратных и фигурных скобок.
- `MACOSX_DEPLOYMENT_TARGET` приложения остаётся 13.5.
- Данные старой версии не читаем и не переносим. Папка данных `Application Support/Tranq`.
- Встроенные наборы `Dictionaries/*.json` и бинарники `gigaam.gguf`, `whisper-cli`, `llama-cli` не переименовываются.
- Версия `3.0.0`, тег `v3.0.0`, к релизу прикладывается `build/Tranq.dmg`.
- Работа в ветке `feat/rebrand-tranq`. PR не создавать, пока пользователь явно не попросит. Только GitHub.
- Каждый коммит заканчивается строкой `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Старые файлы в `docs/superpowers/specs` не переписываются.

Команда тестов, дальше `TEST_CMD`:

```bash
xcodebuild test -project Tranq.xcodeproj -scheme Tranq -destination 'platform=macOS' \
  -only-testing:TranqTests -derivedDataPath build/DerivedData-ci CODE_SIGN_IDENTITY=- \
  | grep -E "error:|Test run with|\*\* TEST"
```

До Задачи 1 вместо `Tranq` в команде стоит `Golosok`.

## Review Focus

1. Приложение не должно читать папку `~/Library/Application Support/Golosok` старой версии. Ожидание: все пути данных строятся от одной константы `AppEnvironment.dataFolderName`. Тест в Задаче 1.
2. Если файл шрифта не найден или не зарегистрирован, текст остаётся читаемым системным шрифтом. Ожидание: любой `Font.Weight` даёт имя Inter, регистрация пустой папки возвращает 0 без падения. Тест в Задаче 3.
3. Моноширинные места, то есть логи, горячие клавиши и код, остаются моноширинными. Ожидание: `design: .monospaced` не уходит в Inter. Тест в Задаче 3.
4. Проверка обновлений и заголовок `X-Title` указывают на Tranq, иначе старые ссылки живут на редиректе. Тест в Задаче 1.
5. Встроенные наборы справочников грузятся после переименования, их десять. Иконка в строке меню существует как ресурс. Тесты в Задачах 1 и 4.

---

### Task 1: Идентификаторы и проект

**Files:**
- Create: `GolosokTests/BrandingTests.swift`, затем переименовывается вместе с папкой
- Modify: `Golosok.xcodeproj/project.pbxproj`, все `*.swift` в `Golosok/` и `GolosokTests/`, `Config/Golosok.entitlements`, `scripts/*.sh`, `.github/workflows/ci.yml`, `.gitignore`, `Golosok/AppEnvironment.swift`, `Golosok/ModelStore.swift:84`, `Golosok/SLMModelStore.swift:150`, `Golosok/UpdateService.swift:15-16`, `Golosok/AIService.swift:348`, `Golosok/ChatRequestBuilder.swift:42`
- Test: `TranqTests/BrandingTests.swift`, `TranqTests/UpdateServiceTests.swift`, `TranqTests/ProviderRequestTests.swift`

**Interfaces:**
- Produces: `AppEnvironment.dataFolderName: String` равна `"Tranq"`; `UpdateService.releasesAPIURL: URL` и `UpdateService.releasesPage: URL`, оба internal static.

- [ ] **Step 1: Создать ветку.** `git switch -c feat/rebrand-tranq`. Файл `docs/superpowers/specs/2026-11-18-tranq-rebrand-design.md` и этот план идут первым коммитом ветки.
- [ ] **Step 2: Написать падающие тесты в `GolosokTests/BrandingTests.swift`**, импорт пока `@testable import Golosok`:
  - `bundleIdentifierIsTranq`: `Bundle.main.bundleIdentifier == "kozak-developer.Tranq"`.
  - `bundleNameIsTranq`: `Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Tranq"`.
  - `dataFolderNameIsTranq`: `AppEnvironment.dataFolderName == "Tranq"`.
  - `builtInPacksStillLoad`: `DictionaryStore.loadPacks(from: .main).count == 10`.
  - В `UpdateServiceTests.swift` тест `updateURLsPointToTranq`: `UpdateService.releasesAPIURL.absoluteString == "https://api.github.com/repos/Nuteres/Tranq/releases/latest"`, `UpdateService.releasesPage.absoluteString == "https://github.com/Nuteres/Tranq/releases"`.
  - В `ProviderRequestTests.swift` проверка, что собранный запрос содержит `X-Title: Tranq`, по образцу существующих тестов файла.
- [ ] **Step 3: Запустить `TEST_CMD` с `Golosok`.** Ожидание: компиляция падает на `dataFolderName` и `releasesAPIURL`.
- [ ] **Step 4: Переименовать каталоги.** `git mv GolosokTests TranqTests`, `git mv Golosok Tranq`, `git mv Golosok.xcodeproj Tranq.xcodeproj`, `git mv Config/Golosok.entitlements Config/Tranq.entitlements`, `git mv Tranq/GolosokApp.swift Tranq/TranqApp.swift`, `git mv Tranq/GolosokSynthProtocol.swift Tranq/TranqSynthProtocol.swift`, `git mv TranqTests/GolosokTests.swift TranqTests/TranqTests.swift`. Игнорируемые git файлы `gigaam.gguf`, `whisper-cli`, `llama-cli` остаются в старой `Golosok/`: перенести обычным `mv` в `Tranq/`, потом удалить пустую `Golosok/`. Группы проекта синхронизируются с диском, поэтому правка отдельных файлов в `pbxproj` не нужна.
- [ ] **Step 5: Заменить идентификаторы в тексте.** По файлам, которые отслеживает git, заменить `Golosok` на `Tranq`, `GOLOSOK` на `TRANQ`, `golosok` на `tranq`. Исключить `docs/superpowers/specs`, `docs/superpowers/plans`, `.git`, `build`. Это покрывает цели и схему в `pbxproj`, `PRODUCT_BUNDLE_IDENTIFIER` в `kozak-developer.Tranq`, `TEST_HOST`, `@testable import Tranq`, `GOLOSOK_*` в скриптах, адрес репозитория, `X-Title`, метки очередей, ключи `tranq-rule-store-`, суффикс набора настроек `kozak-developer.Tranq.tests`, пути `.gitignore`.
- [ ] **Step 6: Ввести `AppEnvironment.dataFolderName: String` и использовать её.** Три места строят путь к `Application Support`: `AppEnvironment.swift:23`, `ModelStore.swift:84`, `SLMModelStore.swift:150`. Все три берут имя из константы.
- [ ] **Step 7: Вынести адреса обновлений.** В `UpdateService.swift` сделать `releasesAPIURL` и `releasesPage` internal static, значения из теста.
- [ ] **Step 8: Проверить результат.** `TEST_CMD`. Ожидание: `** TEST SUCCEEDED **`, новые тесты проходят. Дополнительно `grep -rIn "kozak-developer.Golosok" . --exclude-dir=.git --exclude-dir=build` пусто.
- [ ] **Step 9: Закоммитить.** `git add -A` и сообщение `refactor: rename project, targets and identifiers to Tranq`.

### Task 2: Русское имя и строки интерфейса

**Files:**
- Create: `scripts/check-brand.sh`
- Modify: `Tranq/Localizable.xcstrings`, `Tranq/TranqApp.swift:110-111`, `Tranq/AboutView.swift:21`, `Tranq/SettingsView.swift:291`, `Tranq.xcodeproj/project.pbxproj` (описание микрофона, 3 места)
- Test: `scripts/check-brand.sh`

**Interfaces:**
- Produces: `scripts/check-brand.sh`, выход 0 если в отслеживаемых файлах, кроме `docs/superpowers/specs` и `docs/superpowers/plans`, нет `golosok` без учёта регистра и слов `Голосок`, `Голоска`, `Голоску`, `Голоском`, `Голоске`. При находках печатает строки и выходит с 1.

- [ ] **Step 1: Написать `scripts/check-brand.sh`** на `git grep -nIiE` с исключениями выше. Запустить `bash scripts/check-brand.sh`. Ожидание: выход 1 и список вхождений.
- [ ] **Step 2: Заменить русские строки.** Ключи и переводы в `Localizable.xcstrings`: `Голосок` на `Tranq`, `Развернуть Голосок` на `Развернуть Tranq`, `О программе Golosok` уже стало `О программе Tranq`, английские `About Tranq` и `Open Tranq`. Ключ и значение должны совпадать с литералами в коде. Описание микрофона: `Tranq просит микрофон для транскрипции`.
- [ ] **Step 3: Заменить литералы в коде.** `MenuBarExtra("Tranq", …)`, `Button("Развернуть Tranq")`, `Text("Tranq")` в `AboutView`, журнал запуска.
- [ ] **Step 4: Запустить `bash scripts/check-brand.sh`.** Ожидание: выход 0. Затем `TEST_CMD`, ожидание `** TEST SUCCEEDED **`.
- [ ] **Step 5: Закоммитить.** `git add -A`, сообщение `feat: rename user-facing strings to Tranq`.

### Task 3: Шрифты Inter и Knewave

**Files:**
- Create: `Tranq/BrandFonts.swift`, `Tranq/Fonts/Inter-Regular.ttf`, `Inter-Medium.ttf`, `Inter-SemiBold.ttf`, `Inter-Bold.ttf`, `Knewave-Regular.ttf`, `Tranq/Fonts/OFL-Inter.txt`, `Tranq/Fonts/OFL-Knewave.txt`
- Modify: `Tranq/MonoStyle.swift:85-89`, `Tranq/TranqApp.swift` (вызов регистрации при запуске), `Tranq/EditableTextView.swift:22`
- Test: `TranqTests/BrandFontsTests.swift`

**Interfaces:**
- Produces: `enum BrandFonts` с `static func registerAll(in bundle: Bundle = .main) -> Int`, `static func interName(for weight: Font.Weight) -> String`, `static let knewaveName: String` равной `"Knewave-Regular"`, `static func usesInter(for design: Font.Design) -> Bool`. `Font.brand(_ size: CGFloat) -> Font`. `Font.ui(_:weight:design:)` сохраняет подпись.

- [ ] **Step 1: Получить шрифты.** В пустой папке в scratchpad скачать `Knewave-Regular.ttf` и `OFL.txt` из `google/fonts`, путь `ofl/knewave`, и статические Inter Regular, Medium, SemiBold, Bold с `OFL.txt` из релиза `rsms/inter`. Скачанное считать недоверенным: не запускать ничего из архива. Проверить PostScript-имена через fontTools из отдельного venv, ожидание `Inter-Regular`, `Inter-Medium`, `Inter-SemiBold`, `Inter-Bold`, `Knewave-Regular`. Копировать только `.ttf` и тексты лицензий в `Tranq/Fonts`.
- [ ] **Step 2: Написать падающие тесты `BrandFontsTests`.**
  - `registersAllBundledFonts`: `BrandFonts.registerAll() == 5`.
  - `fontsAreAvailableAfterRegistration`: для каждого из пяти имён `NSFont(name:size: 13) != nil` после регистрации.
  - `interNameCoversEveryWeight`: для `.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black` имя входит в набор четырёх имён Inter. Лёгкие веса дают `Inter-Regular`, тяжёлые `Inter-Bold`.
  - `registeringEmptyBundleReturnsZero`: создать пустую временную папку, `BrandFonts.registerAll(in: Bundle(path: dir)!) == 0` без падения.
  - `onlyDefaultDesignUsesInter`: `BrandFonts.usesInter(for: .default) == true`, для `.monospaced`, `.rounded`, `.serif` значение `false`.
- [ ] **Step 3: Запустить тесты.** Ожидание: FAIL, `BrandFonts` не определён.
- [ ] **Step 4: Реализовать `BrandFonts.registerAll`** через `CTFontManagerRegisterFontsForURLs` для всех `.ttf` из бандла. Искать и в подпапке `Fonts`, и в корне ресурсов, по образцу `DictionaryStore.packFileURLs`. Вернуть число успешно зарегистрированных. Повторная регистрация не считается ошибкой.
- [ ] **Step 5: Переписать `Font.ui`.** Для `design == .default` вернуть `Font.custom(BrandFonts.interName(for: weight), size: size.rawValue)`. Для `.monospaced` и других оставить прежний `.system(size:weight:design:)`, иначе нарушится Review Focus 3. Добавить `Font.brand(_:)` на Knewave.
- [ ] **Step 6: Вызвать `BrandFonts.registerAll()` в инициализации `TranqApp`**, до создания первых окон. В `EditableTextView.swift:22` взять `NSFont(name: "Inter-Regular", size: 15)` с запасным `NSFont.systemFont`.
- [ ] **Step 7: Запустить `TEST_CMD`.** Ожидание: `** TEST SUCCEEDED **`, включая `onlyDefaultDesignUsesInter`. `Font.ui` обращается к `BrandFonts.usesInter(for:)`, поэтому моноширинные места остаются системными.
- [ ] **Step 8: Закоммитить.** `git add -A`, сообщение `feat: bundle Inter and Knewave, route Font.ui through Inter`.

### Task 4: Буква Q, строка меню и иконка

**Files:**
- Create: `Brand/q.svg`, `Brand/extract-q.py`, `Tranq/AppIcon.icon`, `Tranq/Assets.xcassets/MenuBarQ.imageset/`
- Modify: `Tranq/Assets.xcassets/AppLogo.imageset/`, `Tranq/TranqApp.swift:110`
- Delete: `Tranq/Assets.xcassets/AppIcon.appiconset/`
- Test: `TranqTests/BrandAssetsTests.swift`

**Interfaces:**
- Consumes: `Tranq/Fonts/Knewave-Regular.ttf` из Задачи 3.
- Produces: ресурсы `MenuBarQ` и `AppLogo` как шаблонные векторные изображения, иконка `AppIcon`.

- [ ] **Step 1: Написать падающий тест `BrandAssetsTests`.** `menuBarGlyphExists`: `NSImage(named: "MenuBarQ") != nil`. `appLogoExists`: `NSImage(named: "AppLogo") != nil`. Запустить, ожидание FAIL для `MenuBarQ`.
- [ ] **Step 2: Вытащить контур Q.** `Brand/extract-q.py` читает `Knewave-Regular.ttf`, берёт глиф `Q`, рисует его через `SVGPathPen`, переворачивает ось Y и пишет `Brand/q.svg` с `viewBox` по границам глифа. Скрипт запускается из venv вне репозитория, где стоит `fonttools`.
- [ ] **Step 3: Собрать ресурсы.** `MenuBarQ.imageset` и `AppLogo.imageset` с `q.svg`, в `Contents.json` `"template-rendering-intent": "template"` и `"preserves-vector-representation": true`. Старые PNG `icon_idle*` в `AppLogo` удалить.
- [ ] **Step 4: Заменить значок в строке меню.** В `TranqApp.swift:110` при `isRecording == false` показывать `Image("MenuBarQ")`, при записи оставить `record.circle.fill`. В боковой панели `Image("AppLogo")` получает `.foregroundColor(.uiInk)`.
- [ ] **Step 5: Собрать иконку в Icon Composer.** Открыть `Icon Composer.app`, импортировать `Brand/q.svg` одним слоем. Default: фон `#FFFFFF`, Q `#0A0A0A`. Dark: фон `#0A0A0A`, Q `#FAFAFA`. Mono: только Q. Сохранить как `Tranq/AppIcon.icon`. Удалить `AppIcon.appiconset`. Значение `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` остаётся.
- [ ] **Step 6: Проверить сборку иконки.** Собрать Release в `build/DerivedData-icon`. Ожидание: `Tranq.app/Contents/Resources/Assets.car` существует, а `xcrun assetutil --info` по нему показывает записи `AppIcon` с тёмным вариантом. Если тёмного варианта нет, остановиться и сообщить, не подменять иконку.
- [ ] **Step 7: Запустить `TEST_CMD`.** Ожидание: `** TEST SUCCEEDED **`. Закоммитить: `feat: add Q glyph, menu bar template and adaptive app icon`.

### Task 5: Название Knewave в интерфейсе

**Files:**
- Modify: `Tranq/ContentView.swift:234`, `Tranq/AboutView.swift:21`, `Tranq/OnboardingView.swift`

**Interfaces:**
- Consumes: `Font.brand(_ size: CGFloat) -> Font` из Задачи 3.

- [ ] **Step 1: Заменить шрифт названия.** В заголовке боковой панели и в `AboutView` у `Text("Tranq")` поставить `.font(.brand(22))` и `.font(.brand(30))`. Вес убрать, у Knewave один.
- [ ] **Step 2: Онбординг.** Если в `OnboardingView.swift` есть приветственный шаг, добавить над его заголовком `Text("Tranq")` с `.font(.brand(34))`. Если приветственного шага нет, ничего не добавлять и указать это в отчёте.
- [ ] **Step 3: Проверить глазами.** Запустить приложение через skill `run`, снять скриншоты боковой панели, окна «О программе» и онбординга в светлой и тёмной теме. Ожидание: название читаемо, не обрезано, кириллица в соседних строках набрана Inter.
- [ ] **Step 4: Закоммитить.** `feat: set the Tranq wordmark in Knewave`.

### Task 6: Документы, версия, упаковка

**Files:**
- Modify: `README.md`, `README_RU.md`, `AGENTS.md`, `docs/eval.md`, `docs/eval-local-models-2026-11.md`, `scripts/build-dmg.sh`, `Tranq.xcodeproj/project.pbxproj` (`MARKETING_VERSION`), `.github/workflows/ci.yml`

- [ ] **Step 1: Обновить тексты.** В `README.md`, `README_RU.md`, `docs/eval*.md` и `AGENTS.md` имя `Tranq`, пути и команды из Задачи 1. В `AGENTS.md` исправить правило версий так, чтобы оно совпадало с реальным `3.x`, и убрать расхождение с `1.X`.
- [ ] **Step 2: Версия.** `MARKETING_VERSION = 3.0.0` для приложения. Тесты остаются на `1.0`.
- [ ] **Step 3: Упаковка.** В `scripts/build-dmg.sh` имя тома `Tranq`, файл `build/Tranq.dmg`, переменная `TRANQ_DMG`. Если Задача 1 уже заменила их, проверить глазами.
- [ ] **Step 4: Включить проверку бренда в CI.** Перед шагом сборки добавить шаг `bash scripts/check-brand.sh`.
- [ ] **Step 5: Проверить.** `bash scripts/check-brand.sh` выход 0. Закоммитить: `docs: update docs, version and packaging for Tranq`.

### Task 7: Финальная проверка и репозиторий

- [ ] **Step 1: Полная проверка перед отправкой.** `TEST_CMD`, ожидание `** TEST SUCCEEDED **`. `scripts/build-dmg.sh`, ожидание файл `build/Tranq.dmg`. Смонтировать образ и убедиться, что внутри `Tranq.app` и иконка не белая заглушка. Запустить приложение, проверить в обеих темах иконку в Dock, значок Q в строке меню, окно «О программе».
- [ ] **Step 2: Отправить ветку.** `git push -u origin feat/rebrand-tranq`. PR не создавать.
- [ ] **Step 3: Переименовать репозиторий.** Пользователь заранее согласовал это. Перед запуском коротко напомнить ему и дождаться слова «давай». Команда `gh repo rename Tranq --repo Nuteres/Golosok --yes`, затем `git remote set-url origin https://github.com/Nuteres/Tranq.git`. Ожидание: `git ls-remote origin` отвечает без ошибки.
- [ ] **Step 4: Отчитаться.** Сообщить пользователю итоги проверок, ссылку на ветку и что осталось ему: переименовать локальную папку проекта и выдать новые права приложению при первом запуске.

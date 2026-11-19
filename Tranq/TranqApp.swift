import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyActivationPolicy()
        let mic = PermissionManager.shared.isMicGranted
        let ax = PermissionManager.shared.isAccessibilityGranted
        AppLogger.shared.info("App", "Запуск Tranq",
                              details: "версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"), микрофон: \(mic), доступ AX: \(ax)")
        let hotKey = NativeHotKeyManager.shared
        hotKey.isExternalRecordingActive = {
            AudioCapture.shared.isRecording
        }
        hotKey.onHotKeyPressed = {
            if hotKey.mode == .pushToTalk {
                if !AudioCapture.shared.isRecording {
                    AudioCapture.shared.startRecording()
                }
            } else {
                AudioCapture.shared.toggleRecording()
            }
        }
        hotKey.onHotKeyReleased = {
            if hotKey.mode == .pushToTalk, AudioCapture.shared.isRecording {
                AudioCapture.shared.stopRecording()
            }
        }
        hotKey.register()

        // Словарь создаётся на главном потоке при запуске: загрузка и сборка индекса
        // успевают до первой диктовки, а не выполняются на очереди конвейера посреди неё
        if !AppEnvironment.isRunningTests {
            SpellCommonWordChecker.shared.warmUp()
            _ = DictionaryStore.shared
            // Сокет двери живёт всё время работы приложения: отказы при выключенном доступе выдаёт сама дверь
            MCPSocketServer.shared.start(door: MCPDoor(
                dictionary: DictionaryStore.shared,
                history: HistoryStore.shared,
                access: MCPAccess.shared,
                language: DictionaryScreenLogic.currentUILanguage
            ))
        }

        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: {
                !($0 is NSPanel) &&
                $0.styleMask.contains(.titled) &&
                !$0.className.contains("StatusBar")
            }) {
                MainWindowController.shared.register(window: window)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Убирает файл сокета, чтобы следующий запуск и клиенты не видели мёртвый сокет
        MCPSocketServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.shared.showMainWindow()
        }
        return true
    }
}

@main
struct TranqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var audioCapture = AudioCapture.shared
    @ObservedObject var theme = ThemeSettings.shared
    @ObservedObject var hotKeySettings = HotKeySettings.shared
    @ObservedObject var preferences = AppPreferences.shared

    init() {
        BrandFonts.registerAll()
        LanguageSettings.shared.apply()
        ThemeSettings.shared.apply()
        // Под тестами уборка тронула бы настоящие данные пользователя
        if !AppEnvironment.isRunningTests {
            Task.detached(priority: .utility) {
                LegacyCleanup.run()
                SLMModelStore.shared.removeRetiredModels()
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(theme.current.colorScheme)
                .ignoresSafeArea()
                .frame(minWidth: WindowMetrics.minWidth, minHeight: WindowMetrics.minHeight)
        }
        .windowStyle(.hiddenTitleBar)
        
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Боковое меню") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("О программе") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: NSNotification.Name("OpenAboutModal"), object: nil)
                }
            }

            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") {
                    MainWindowController.shared.showMainWindow()
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsTab"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button(String(localized: "Вставить оригинал речи")) {
                    TranscriptJournal.shared.pasteOriginal { _ in }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
            }
        }

        .defaultSize(width: 990, height: 710)
        
        MenuBarExtra {
            Text("Режим")
            ForEach(HotKeyMode.allCases) { mode in
                Button {
                    hotKeySettings.mode = mode
                } label: {
                    if hotKeySettings.mode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }

            Divider()

            Button {
                preferences.soundEnabled.toggle()
            } label: {
                if preferences.soundEnabled {
                    Label("Звуки", systemImage: "checkmark")
                } else {
                    Text("Звуки")
                }
            }

            Divider()

            Button("Развернуть Tranq") {
                MainWindowController.shared.showMainWindow()
            }
            
            Button("Настройки…") {
                MainWindowController.shared.showMainWindow()
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsTab"), object: nil)
            }
            
            Divider()
            
            Button("Завершить") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            if audioCapture.isRecording {
                Image(systemName: "record.circle.fill")
            } else {
                Image(nsImage: BrandAssets.menuBarMark())
            }
        }
    }
}

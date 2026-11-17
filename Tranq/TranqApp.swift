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
        hotKey.onHotKeyPressed = { promptRequested in
            if hotKey.mode == .pushToTalk {
                if !AudioCapture.shared.isRecording {
                    AudioCapture.shared.startRecording(promptRequested: promptRequested)
                }
            } else {
                AudioCapture.shared.toggleRecording(promptRequested: promptRequested)
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

    init() {
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
                .frame(minWidth: 990, minHeight: 710)
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

            CommandGroup(after: .pasteboard) {
                Button(String(localized: "Вставить оригинал речи")) {
                    TranscriptJournal.shared.pasteOriginal { _ in }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
            }
        }

        .defaultSize(width: 990, height: 710)
        
        MenuBarExtra("Голосок", systemImage: audioCapture.isRecording ? "record.circle.fill" : "waveform") {
            Button("Развернуть Голосок") {
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
        }
    }
}

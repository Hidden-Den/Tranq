import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyActivationPolicy()
        let mic = PermissionManager.shared.isMicGranted
        let ax = PermissionManager.shared.isAccessibilityGranted
        AppLogger.shared.info("App", "Запуск Golosok",
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

        // Словарь создаётся на главном потоке при запуске: перенос старых данных и сборка индекса
        // успевают до первой диктовки, а не выполняются на очереди конвейера посреди неё
        if !AppEnvironment.isRunningTests {
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
struct GolosokApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var audioCapture = AudioCapture.shared
    @ObservedObject var theme = ThemeSettings.shared

    init() {
        LanguageSettings.shared.apply()
        ThemeSettings.shared.apply()
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

            CommandGroup(replacing: .newItem) {
                Button("Открыть аудиофайл...") {
                    AudioCapture.shared.importAndTranscribeFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button(String(localized: "Вставить оригинал речи")) {
                    TranscriptJournal.shared.pasteOriginal { _ in }
                }
                .keyboardShortcut("z", modifiers: [.command, .option])
            }

            CommandGroup(after: .textEditing) {
                Button("Найти в стенограмме…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleTranscriptSearch"), object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Найти далее") {
                    NotificationCenter.default.post(name: NSNotification.Name("FindNextInTranscript"), object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Найти ранее") {
                    NotificationCenter.default.post(name: NSNotification.Name("FindPreviousInTranscript"), object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
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

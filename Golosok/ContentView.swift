import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MainTab { case vocabulary, history, settings }

struct DateFormattingHelper {
    private static let inputFormatter: DateFormatter = { let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"; return df }()
    private static let outputFormatter: DateFormatter = { let df = DateFormatter(); df.locale = Locale.current; df.dateFormat = "d MMMM yyyy"; return df }()
    static func formatRussianDate(_ dateStr: String) -> (date: String, time: String) {
        let parts = dateStr.components(separatedBy: ", ")
        let datePart = parts.first ?? dateStr; let timePart = parts.count > 1 ? parts[1] : ""
        if let dateObj = inputFormatter.date(from: datePart) { return (outputFormatter.string(from: dateObj), timePart) }
        return (datePart, timePart)
    }
}

struct ContentView: View {
    @ObservedObject var audioCapture = AudioCapture.shared
    @ObservedObject var historyStore = HistoryStore.shared
    @ObservedObject var playback = PlaybackController.shared
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var permissions = PermissionManager.shared
    
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = true
    
    @State private var currentTab: MainTab = .history
    @State private var selectedItemId: UUID?
    @State private var showOnboarding = false
    
    @State private var searchText = ""
    @State private var filteredResults: [TranscriptionItem] = []
    @State private var searchDebounce: DispatchWorkItem?
    @State private var isSearching = false
    @State private var itemToDelete: UUID?
    @State private var showingDeleteAlert = false
    
    @State private var showAboutSheet = false

    private var currentTabTitle: String {
        switch currentTab {
        case .vocabulary: return String(localized: "Словарь")
        case .history: return String(localized: "История")
        case .settings: return String(localized: "Настройки")
        }
    }
    
    private func toggleSidebar() {
        withAnimation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.52)) {
            isSidebarVisible.toggle()
        }
    }
    
    private var displayedHistory: [TranscriptionItem] {
        searchText.isEmpty ? historyStore.items : filteredResults
    }
    
    var body: some View {
        ZStack {
            if !permissions.onboardingCompleted {
                OnboardingView(isPresented: $showOnboarding)
            } else {
                mainInterface
            }
        }
        .transition(.opacity)
        .onAppear { permissions.checkPermissions() }
        .ignoresSafeArea()
        // Автоматическое открытие заметки
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AutoSelectNote"))) { notification in
            if preferences.autoOpenNoteEnabled, let newId = notification.object as? UUID {
                withAnimation {
                    self.currentTab = .history
                    self.searchText = ""
                    self.selectedItemId = newId
                }
                historyStore.markAsRead(id: newId)
            }
        }
        .sheet(isPresented: $showAboutSheet) {
            AboutView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenAboutModal"))) { _ in
            showAboutSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            UpdateService.shared.checkUpdates()
        }
        .onChange(of: searchText) { newValue in
            scheduleSearch(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsTab"))) { _ in
            currentTab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenVocabularyTab"))) { _ in
            currentTab = .vocabulary
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleSidebar"))) { _ in
            toggleSidebar()
        }
        .background(WindowAccessor())
    }

    private func scheduleSearch(_ query: String) {
        searchDebounce?.cancel()
        if query.isEmpty {
            withAnimation(.easeOut(duration: 0.16)) {
                isSearching = false
                filteredResults = []
            }
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            isSearching = true
        }
        let item = DispatchWorkItem {
            self.performSearch(query)
        }
        searchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: item)
    }

    private func performSearch(_ query: String) {
        let history = historyStore.items
        DispatchQueue.global(qos: .userInitiated).async {
            let results = history.filter {
                $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            DispatchQueue.main.async {
                guard self.searchText == query else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    self.filteredResults = results
                    self.isSearching = false
                }
            }
        }
    }
    
    var mainInterface: some View {
        VStack(spacing: 0) {
            topBar
            
            HStack(spacing: 0) {
                sidebarColumn
                    .frame(width: 260)
                    .offset(x: isSidebarVisible ? 0 : -40)
                    .opacity(isSidebarVisible ? 1.0 : 0.0)
                    .frame(width: isSidebarVisible ? 260 : 0, alignment: .leading)
                    .clipped()
                
                Group {
                    switch currentTab {
                    case .vocabulary: DictionaryView()
                    case .history: historyDetailView
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 840, minHeight: 520)
        .background(Color.uiCanvas)
        .ignoresSafeArea()
    }
    
    private var topBar: some View {
        HStack(spacing: 8) {
            // Точный отступ под светофор macOS (красная, жёлтая, зелёная кнопки: x = 18..66)
            Spacer().frame(width: 76)
            
            // Кнопка сворачивания, центр которой строго совпадает с осью светофора (y = 16.2 pt)
            sidebarToggleButton
            
            // Заголовок раздела показывается ТОЛЬКО когда боковое меню скрыто, чтобы не дублировать
            if !isSidebarVisible {
                Text(currentTabTitle)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundColor(.uiInk)
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
            
            Spacer()
        }
        .frame(height: 32.5)
    }
    
    private var sidebarToggleButton: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.leading")
                .font(.ui(.body, weight: .medium))
                .foregroundColor(.uiInkSoft)
                .frame(width: 26, height: 26)
                .background(Color.uiPaper.opacity(0.6))
                .cornerRadius(UIRadius.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
        .help(isSidebarVisible ? LocalizedStringKey("Скрыть меню") : LocalizedStringKey("Показать меню"))
    }
    
    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            sidebarHeader
            VStack(spacing: 4) {
                SidebarTabButton(title: "Словарь", icon: "character.book.closed.fill", isActive: currentTab == .vocabulary) {
                    currentTab = .vocabulary
                    searchText = ""
                }
                SidebarTabButton(title: "История", icon: "clock.fill", isActive: currentTab == .history) {
                    currentTab = .history
                    selectedItemId = nil
                }
                SidebarTabButton(title: "Настройки", icon: "gearshape.fill", isActive: currentTab == .settings) {
                    currentTab = .settings
                    searchText = ""
                }
            }
            .padding(.horizontal, 8)
            
            if currentTab == .history { historySearchAndList } else { Spacer() }
            sidebarFooter
        }
        .padding(.top, 4)
        .frame(width: 260)
        .background(Color.uiCanvas)
    }
    
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image("AppLogo").resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22).cornerRadius(UIRadius.xs)
            VStack(alignment: .leading, spacing: -2) {
                Text("Голосок").font(.ui(.callout, weight: .bold)).foregroundColor(.uiInk)
                HStack(spacing: 4) {
                    let versionStr = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    Text(versionStr).font(.ui(.micro, weight: .medium)).foregroundColor(.uiMidGray)
                }
            }
            Spacer()
        }.padding(.horizontal, 16)
    }
    
    private var historySearchAndList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    if isSearching {
                        ProgressView().controlSize(.small)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Image(systemName: "magnifyingglass").foregroundColor(.uiMidGray)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    TextField("Поиск...", text: $searchText).textFieldStyle(PlainTextFieldStyle()).font(.ui(.body)).foregroundColor(.uiInk)
                    if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.uiMidGray) }.buttonStyle(.plain) }
                }
                .padding(8).background(Color.uiPaper).cornerRadius(UIRadius.sm).overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
            }.padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if isSearching {
                        ForEach(0..<4, id: \.self) { _ in
                            HistorySkeletonCard()
                        }
                    } else if displayedHistory.isEmpty {
                        Text(searchText.isEmpty ? LocalizedStringKey("История пуста") : LocalizedStringKey("Ничего не найдено")).font(.ui(.body)).foregroundColor(.uiMidGray).padding(.vertical, 20)
                    } else {
                        ForEach(displayedHistory) { item in
                            Button {
                                selectedItemId = item.id
                                historyStore.markAsRead(id: item.id) // Гасим точку при клике руками
                            } label: {
                                HistoryCard(item: item, isSelected: selectedItemId == item.id)
                            }
                            .buttonStyle(TactileButtonStyle())
                        }
                    }
                }.padding(.horizontal, 8)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSearching)
    }
    
    private var sidebarFooter: some View {
        HStack {
            Circle().fill(audioCapture.isRecording ? Color.uiEmber : Color.green).frame(width: 8, height: 8)
            Text(audioCapture.isRecording ? LocalizedStringKey("Запись...") : LocalizedStringKey("Готов к работе")).font(.ui(.footnote)).foregroundColor(.uiMidGray)
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
    
    var historyDetailView: some View {
        ZStack {
            Color.uiCanvas.ignoresSafeArea()
            VStack {
                if let selected = historyStore.items.first(where: { $0.id == selectedItemId }) {
                    HistoryNoteView(item: selected) {
                        itemToDelete = selected.id
                        showingDeleteAlert = true
                    }
                    .id(selected.id)
                } else {
                    emptyHistoryCard
                }
            }.padding(20)
        }
        .onChange(of: selectedItemId) { _ in playback.stopSyncedPlayback() }
        .onChange(of: currentTab) { _ in playback.stopSyncedPlayback() }
        .alert("Удалить запись?", isPresented: $showingDeleteAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Удалить", role: .destructive) {
                if let id = itemToDelete, let idx = historyStore.items.firstIndex(where: { $0.id == id }) {
                    SoundEffect.playDelete()
                    playback.stopSyncedPlayback()
                    historyStore.deleteItem(at: idx)
                    if selectedItemId == id { selectedItemId = nil }
                }
            }
        } message: { Text("Это действие нельзя отменить.") }
    }

    private var emptyHistoryCard: some View {
        UICard {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image("AppLogo")
                            .resizable()
                            .frame(width: 26, height: 26)
                            .cornerRadius(UIRadius.sm)
                        Text("Голосок")
                            .font(.ui(.title, weight: .bold))
                            .foregroundColor(.uiInk)
                    }
                    Text("Чистый текст голосом в любом приложении")
                        .font(.ui(.body))
                        .foregroundColor(.uiMidGray)
                        .multilineTextAlignment(.center)
                }
                HeroActionRow(
                    icon: "mic.fill",
                    badge: NativeHotKeyManager.shared.displayName(),
                    title: "Надиктовать",
                    subtitle: "Текст сразу появится под курсором"
                ) {
                    audioCapture.toggleRecording()
                }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - ВСПОМОГАТЕЛЬНЫЕ КОМПОНЕНТЫ

struct HeroActionRow: View {
    let icon: String
    let badge: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: UIRadius.md, style: .continuous).fill(Color.uiCanvas)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon).font(.ui(.headline, weight: .semibold)).foregroundColor(.uiInk)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(.callout, weight: .semibold)).foregroundColor(.uiInk)
                    Text(subtitle).font(.ui(.footnote)).foregroundColor(.uiMidGray).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(badge).font(.ui(.micro, weight: .semibold)).tracking(0.5).foregroundColor(.uiMidGray)
                Image(systemName: "chevron.right").font(.ui(.micro, weight: .bold)).foregroundColor(.uiMidGray)
            }
            .padding(14)
            .background(Color.uiSidebar)
            .cornerRadius(UIRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.lg).stroke(Color.uiHairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
    }
}

struct CopyFeedbackButton: View {
    let textToCopy: String
    @State private var isCopied = false
    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToCopy, forType: .string)
            SoundEffect.playCopy()
            withAnimation(.spring()) { isCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(.spring()) { isCopied = false } }
        }) {
            HStack(spacing: 6) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.ui(.caption, weight: .medium))
                Text(isCopied ? LocalizedStringKey("Готово!") : LocalizedStringKey("Скопировать"))
            }
            .lineLimit(1)
            .font(.ui(.body, weight: .medium))
            .foregroundColor(isCopied ? Color.uiSuccess : .uiInk)
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(Color.uiPaper).cornerRadius(UIRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.lg).stroke(isCopied ? Color.uiSuccess.opacity(0.5) : Color.uiHairline, lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SidebarTabButton: View {
    let title: LocalizedStringKey
    let icon: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: icon).font(.ui(.body)); Text(title).font(.ui(.body, weight: .medium)); Spacer() }
            .foregroundColor(isActive ? .uiPaper : .uiInk).padding(.vertical, 8).padding(.horizontal, 12)
            .background(isActive ? Color.uiInk : Color.clear).cornerRadius(UIRadius.md).contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
    }
}
// СИСТЕМНАЯ КАРТОЧКА С СИНЕЙ ТОЧКОЙ
// СКЕЛЕТОН КАРТОЧКИ ПРИ ПОИСКЕ
struct HistorySkeletonCard: View {
    private var bar: Color { Color.uiMidGray.opacity(0.16) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(Color.blue.opacity(0.4)).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: UIRadius.xs).fill(bar).frame(width: 56, height: 8)
                    RoundedRectangle(cornerRadius: UIRadius.xs).fill(bar).frame(width: 30, height: 8)
                    Spacer()
                    RoundedRectangle(cornerRadius: UIRadius.xs).fill(bar).frame(width: 40, height: 8)
                }
                RoundedRectangle(cornerRadius: UIRadius.xs).fill(bar).frame(height: 9)
                RoundedRectangle(cornerRadius: UIRadius.xs).fill(bar).frame(width: 180, height: 9)
            }
            .shimmer()
        }
        .padding(12)
    }
}

struct HistoryCard: View {
    let item: TranscriptionItem
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // СИНЯЯ ТОЧКА НЕПРОЧИТАННОГО!
                if item.isUnread == true {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
                
                let formatted = DateFormattingHelper.formatRussianDate(item.date)
                Text(formatted.date).font(.ui(.footnote, weight: .semibold)).foregroundColor(isSelected ? .uiInk : .uiInkSoft)
                if !formatted.time.isEmpty { Text(formatted.time).font(.ui(.micro)).foregroundColor(isSelected ? .uiMidGray : .uiMidGray.opacity(0.8)) }
                Spacer()
                Text(item.duration).font(.ui(.micro)).foregroundColor(.uiMidGray)
            }
            Text(item.text).font(.ui(.body)).foregroundColor(isSelected ? .uiInk : .uiInkSoft).lineLimit(2)
        }
        .padding(12).background(isSelected ? Color.uiPaper : Color.clear).cornerRadius(UIRadius.md)
        .overlay(RoundedRectangle(cornerRadius: UIRadius.md).stroke(isSelected ? Color.uiHairline : Color.clear, lineWidth: 1))
        .shadow(color: isSelected ? Color.black.opacity(0.04) : Color.clear, radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

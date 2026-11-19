import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MainTab: CaseIterable {
    case vocabulary, rules, history, settings

    var title: String {
        switch self {
        case .vocabulary: return String(localized: "Словарь")
        case .rules: return String(localized: "Правила")
        case .history: return String(localized: "История")
        case .settings: return String(localized: "Настройки")
        }
    }
}

/// Наименьший размер главного окна. Одно значение на окно и на содержимое:
/// раньше они расходились, и окно упиралось в больший из двух пределов.
enum WindowMetrics {
    static let minWidth: CGFloat = 860
    static let minHeight: CGFloat = 560
}

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
    @ObservedObject var updates = UpdateService.shared
    
    @AppStorage("isSidebarVisible") private var isSidebarVisible: Bool = true
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    /// Выбранный раздел настроек. Ключ общий с `SettingsSection.restore`.
    @AppStorage(SettingsSection.storageKey) private var settingsSectionRaw: String = SettingsSection.dictation.rawValue

    private var selectedSettingsSection: SettingsSection {
        SettingsSection.from(raw: settingsSectionRaw)
    }

    /// Границы ширины списка: уже — обрезает даты, шире — душит содержимое.
    static let sidebarMinWidth: Double = 220
    static let sidebarMaxWidth: Double = 420

    @State private var dragStartSidebarWidth: Double?
    @State private var isOverSidebarEdge = false
    /// Высота курсора над границей в координатах подложки: отсюда расходится подсветка.
    @State private var edgeGlowY: CGFloat = 0
    
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

    private var currentTabTitle: String { currentTab.title }
    
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
            // Открытое окно не трогаем: новая запись остаётся непрочитанной, на неё указывает точка в истории
            if AutoOpenPolicy.shouldSwitchToHistory(
                autoOpenEnabled: preferences.autoOpenNoteEnabled,
                isWindowVisible: MainWindowController.shared.isMainWindowOnScreen
            ), let newId = notification.object as? UUID {
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
            // Права могли выдать в системных настройках: строка проблемы в сайдбаре должна исчезнуть
            permissions.refreshPermissions()
            UpdateService.shared.checkUpdates()
        }
        .onChange(of: searchText) { newValue in
            scheduleSearch(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsTab"))) { _ in
            // Со свёрнутым меню список разделов недоступен, поэтому раскрываем его вместе с переходом
            isSidebarVisible = true
            currentTab = .settings
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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Полоса под светофор macOS: красная, жёлтая, зелёная кнопки занимают x = 18..66
                Color.clear.frame(height: Self.titleBarHeight)
                sidebarColumn
            }
            .frame(width: sidebarWidth)
            .offset(x: isSidebarVisible ? 0 : -40)
            .opacity(isSidebarVisible ? 1.0 : 0.0)
            .frame(width: isSidebarVisible ? sidebarWidth : 0, alignment: .leading)
            .clipped()

            contentPanel
                .padding(.top, isSidebarVisible ? Self.panelInset : Self.titleBarHeight)
                .padding(.leading, isSidebarVisible ? 0 : Self.panelInset)
                .padding([.trailing, .bottom], Self.panelInset)
        }
        .coordinateSpace(name: Self.mainAreaSpace)
        // Заголовок раздела показывается только при скрытом меню, чтобы не дублировать
        .overlay(alignment: .topLeading) {
            if !isSidebarVisible {
                Text(currentTabTitle)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundColor(.uiInk)
                    .frame(height: Self.titleBarHeight)
                    .padding(.leading, 82)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: WindowMetrics.minWidth, minHeight: WindowMetrics.minHeight)
        .background(Color.uiWindow)
        .ignoresSafeArea()
    }

    static let titleBarHeight: CGFloat = 32.5
    /// Отступ подложки от краёв окна, как у Linear.
    static let panelInset: CGFloat = 8
    static let panelRadius: CGFloat = UIRadius.md
    static let mainAreaSpace = "mainArea"
    /// Длина светящегося отрезка на границе: гаснет к концам от точки курсора.
    static let edgeGlowLength: CGFloat = 280

    /// Подложка содержимого другого цвета. Её левый край и есть граница, за которую тянут меню.
    private var contentPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
        return Group {
            switch currentTab {
            case .vocabulary: DictionaryView()
            case .rules: RulesView()
            case .history: historyDetailView
            case .settings: SettingsView(section: selectedSettingsSection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.uiPanel)
        .clipShape(shape)
        .overlay(shape.stroke(Color.uiHairline, lineWidth: 1))
        .overlay(alignment: .topLeading) { edgeGlow.clipShape(shape) }
        .overlay(alignment: .leading) {
            if isSidebarVisible { sidebarResizeHandle }
        }
    }

    private var isEdgeActive: Bool { isOverSidebarEdge || dragStartSidebarWidth != nil }

    /// Подсветка границы: ярче всего там, где курсор взялся за край, и гаснет вверх и вниз.
    private var edgeGlow: some View {
        Color.clear.overlay(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Color.uiInk.opacity(0), location: 0),
                    .init(color: Color.uiInk.opacity(0.6), location: 0.5),
                    .init(color: Color.uiInk.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: 1.5, height: Self.edgeGlowLength)
            .offset(y: edgeGlowY - Self.edgeGlowLength / 2)
        }
        .opacity(isEdgeActive ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isEdgeActive)
        .allowsHitTesting(false)
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            sidebarHeader
            VStack(spacing: 4) {
                SidebarTabButton(title: "Словарь", icon: "character.book.closed.fill", isActive: currentTab == .vocabulary) {
                    currentTab = .vocabulary
                    searchText = ""
                }
                SidebarTabButton(title: "Правила", icon: "slider.horizontal.3", isActive: currentTab == .rules) {
                    currentTab = .rules
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
            
            if currentTab == .history {
                historySearchAndList
            } else if currentTab == .settings {
                settingsSectionList
            } else {
                Spacer()
            }
            sidebarFooter
        }
        .padding(.top, 4)
        .frame(width: sidebarWidth)
        .background(Color.uiWindow)
    }

    /// Невидимая полоса захвата поверх левого края подложки.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 11)
            .contentShape(Rectangle())
            .offset(x: -5.5)
            .onContinuousHover { phase in
                // Курсор-стрелка подсказывает, что за край можно взяться.
                // Флаг держит push и pop в паре: лишний pop ломает курсор всего приложения.
                switch phase {
                case .active(let location):
                    if dragStartSidebarWidth == nil { edgeGlowY = location.y }
                    guard !isOverSidebarEdge else { return }
                    isOverSidebarEdge = true
                    NSCursor.resizeLeftRight.push()
                case .ended:
                    guard isOverSidebarEdge else { return }
                    isOverSidebarEdge = false
                    NSCursor.pop()
                }
            }
            // Сайдбар скрыли клавишей над ручкой: onHover не придёт, а курсор должен вернуться
            .onDisappear {
                guard isOverSidebarEdge else { return }
                isOverSidebarEdge = false
                NSCursor.pop()
            }
            .gesture(
                // Неподвижная система координат окна: ручка едет за мышью, и в её собственной сдвиг считался бы от уехавшей точки
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.mainAreaSpace))
                    .onChanged { value in
                        let start = dragStartSidebarWidth ?? sidebarWidth
                        if dragStartSidebarWidth == nil { dragStartSidebarWidth = start }
                        sidebarWidth = min(Self.sidebarMaxWidth, max(Self.sidebarMinWidth, start + value.translation.width))
                        edgeGlowY = value.location.y - Self.panelInset
                    }
                    .onEnded { _ in dragStartSidebarWidth = nil }
            )
    }
    
    /// Только название. Версия живёт в «О программе»: в рабочем экране она
    /// ничего не решает и спорит со знаком бренда за внимание.
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Text("Tranq")
                .font(.brand(28))
                .foregroundColor(.uiInk)
                .padding(.bottom, 2)
            Spacer()
        }.padding(.horizontal, 16)
    }
    
    /// Шесть разделов настроек под кнопками вкладок, там же, где для истории список записей.
    private var settingsSectionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().background(Color.uiHairline).padding(.horizontal, 12).padding(.bottom, 6)
            ForEach(SettingsSection.allCases) { section in
                SidebarTabButton(title: LocalizedStringKey(section.title), icon: section.icon, isActive: section == selectedSettingsSection) {
                    settingsSectionRaw = section.rawValue
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
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
        VStack(alignment: .leading, spacing: 8) {
            if let update = updates.updateInfo {
                Button { NSWorkspace.shared.open(update.url) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").font(.ui(.footnote))
                        Text(String(format: String(localized: "Доступна %@"), update.version)).font(.ui(.footnote, weight: .medium))
                    }
                    .foregroundColor(.uiInk)
                }
                .buttonStyle(.plain)
            }
            if let issue = permissionIssue {
                Button { issue.resolve() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.uiAmber).frame(width: 8, height: 8)
                        Text(issue.title).font(.ui(.footnote, weight: .medium))
                    }
                    .foregroundColor(.uiInk)
                }
                .buttonStyle(.plain)
                .help(Text("Открыть настройки macOS"))
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    /// Что мешает диктовке прямо сейчас. Пусто, когда всё в порядке:
    /// постоянная надпись «готов» ничего не сообщает и только занимает место.
    private var permissionIssue: PermissionIssue? {
        if !permissions.isMicGranted { return .microphone }
        if preferences.autoPasteEnabled && !permissions.isAccessibilityGranted { return .accessibility }
        return nil
    }

    /// Нехватка доступа, которую можно починить одним нажатием.
    enum PermissionIssue {
        case microphone
        case accessibility

        var title: LocalizedStringKey {
            switch self {
            case .microphone: return "Нет доступа к микрофону"
            case .accessibility: return "Нет универсального доступа"
            }
        }

        func resolve() {
            switch self {
            case .microphone: PermissionManager.shared.resolveMicPermission()
            case .accessibility: PermissionManager.shared.requestAccessibilityPermission()
            }
        }
    }
    
    var historyDetailView: some View {
        ZStack {
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
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
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

    /// Пустое состояние лежит прямо на подложке, без своей карточки.
    private var emptyHistoryCard: some View {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Tranq")
                            .font(.brand(30))
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
                .frame(maxWidth: 520)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack(spacing: 10) { Image(systemName: icon).font(.ui(.body)).frame(width: 20); Text(title).font(.ui(.body, weight: .medium)); Spacer() }
            .foregroundColor(.uiInk).padding(.vertical, 8).padding(.horizontal, 12)
            // Выбранный пункт отмечен мягкой плашкой, как у Linear, а не залитой инверсией
            .background(isActive ? Color.uiSelection : Color.clear).cornerRadius(UIRadius.md).contentShape(Rectangle())
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

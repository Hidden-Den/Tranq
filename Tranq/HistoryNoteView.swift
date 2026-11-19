import SwiftUI
import AppKit

/// Экран выбранной заметки: одна строка управления, текст с правкой по клику и строка плеера.
///
/// Создаётся заново для каждой заметки через `.id(item.id)`, поэтому черновик правки
/// живёт в собственном состоянии и записывается при уходе с заметки.
struct HistoryNoteView: View {
    let item: TranscriptionItem
    let onDelete: () -> Void

    @ObservedObject private var playback = PlaybackController.shared
    @State private var draft: String
    @State private var showsSpoken = false
    @State private var saveWork: DispatchWorkItem?

    init(item: TranscriptionItem, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        _draft = State(initialValue: item.text)
    }

    private var visibleText: String {
        showsSpoken ? (item.spokenText ?? "") : draft
    }

    var body: some View {
        // Запись лежит прямо на подложке: вторая карточка внутри неё дала бы двойную рамку
        Group {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider().background(Color.uiHairline)
                textArea
                if playback.hasAudio(for: item.id) {
                    playerRow
                }
            }
        }
        .onAppear { playback.prepare(for: item.id) }
        .onDisappear { saveNow() }
        .onChange(of: showsSpoken) { _ in saveNow() }
    }

    // MARK: - Строка управления

    private var header: some View {
        let formatted = DateFormattingHelper.formatRussianDate(item.date)
        let meta = [formatted.time, item.duration == "—" ? "" : item.duration]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatted.date)
                    .font(.ui(.callout, weight: .bold))
                    .foregroundColor(.uiInk)
                    .lineLimit(1)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.ui(.caption))
                        .foregroundColor(.uiMidGray)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if item.showsSpokenToggle {
                Picker("", selection: $showsSpoken) {
                    Text("Итог").tag(false)
                    Text("Сказано").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            CopyFeedbackButton(textToCopy: visibleText)
            UIDropdownMenu(items: [
                .action("Вставить ещё раз", icon: "arrow.uturn.forward") { pasteAgain() },
                .divider,
                .action("Удалить", icon: "trash") { onDelete() }
            ], minWidth: 200) {
                Image(systemName: "ellipsis")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundColor(.uiInk)
                    .frame(width: 34, height: 34)
                    .background(Color.uiPaper)
                    .cornerRadius(UIRadius.lg)
                    .overlay(RoundedRectangle(cornerRadius: UIRadius.lg).stroke(Color.uiHairline, lineWidth: 1))
            }
            .fixedSize()
            .help(String(localized: "Ещё"))
        }
    }

    // MARK: - Текст

    @ViewBuilder
    private var textArea: some View {
        if showsSpoken {
            EditableTextView(text: .constant(item.spokenText ?? ""), isEditable: false, autoFocus: false)
        } else {
            ZStack(alignment: .topLeading) {
                EditableTextView(text: $draft, autoFocus: false) { scheduleSave($0) }
                if draft.isEmpty {
                    Text("Начните вводить текст…")
                        .font(.ui(.callout))
                        .foregroundColor(.uiMidGray.opacity(0.55))
                        .padding(.top, 10)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Плеер

    private var playerRow: some View {
        let isCurrent = playback.playingItemId == item.id
        let duration = playback.durations[item.id] ?? 0
        let playhead = isCurrent ? playback.playheadTime : 0
        return HStack(spacing: 10) {
            Button(action: { playback.toggleSyncedPlayback(for: item.id) }) {
                Image(systemName: isCurrent && playback.isPlayerPlaying ? "pause.fill" : "play.fill")
                    .font(.ui(.caption, weight: .bold))
                    .foregroundColor(.uiInkSoft)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCurrent && playback.isPlayerPlaying ? String(localized: "Пауза") : String(localized: "Слушать"))
            UISeekSlider(value: Binding(
                get: { playhead },
                set: { playback.seekSynced(to: $0, for: item.id) }
            ), range: 0...max(duration, 0.01))
            Text(Self.formatTime(isCurrent ? playhead : duration))
                .font(.ui(.caption, weight: .medium, design: .monospaced))
                .foregroundColor(.uiMidGray)
                .monospacedDigit()
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Действия

    private func scheduleSave(_ text: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [id = item.id] in
            HistoryStore.shared.replaceNoteText(id: id, text: text)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        HistoryStore.shared.replaceNoteText(id: item.id, text: draft)
    }

    /// Прячет Tranq и вставляет текст в приложение, которое стало активным.
    private func pasteAgain() {
        saveNow()
        let text = visibleText
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let target = InsertionService.shared.captureFocus()
            InsertionService.shared.paste(text: text, target: target, autoPasteEnabled: true) { _ in }
        }
    }
}

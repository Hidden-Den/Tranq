import SwiftUI

// MARK: - Окно добавления слова

/// Ввод написания с мгновенным и асинхронным подбором вариантов и необязательной записью 🎙.
struct DictionaryAddWordSheet: View {
    @ObservedObject private var store = DictionaryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var spelling = ""
    @State private var draft = AddWordDraft()
    @FocusState private var fieldFocused: Bool

    private let language = DictionaryLanguage.current

    private var trimmed: String { spelling.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Слово", text: $spelling)
                .textFieldStyle(.plain)
                .font(.ui(.title, weight: .semibold))
                .foregroundColor(.uiInk)
                .focused($fieldFocused)
                .onSubmit(add)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.uiCanvas)
                .cornerRadius(UIRadius.sm)
                .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))

            let variants = draft.variants(for: language)
            if !variants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Узнаю как")
                        .font(.ui(.caption, weight: .medium))
                        .foregroundColor(.uiMidGray)
                    FlowLayout(spacing: 6) {
                        ForEach(variants, id: \.self) { variant in
                            VariantChip(text: variant) { draft.remove(variant, language: language) }
                        }
                    }
                }
            }

            WordProbeControl(spelling: trimmed) { draft.addRecorded($0, language: language) }

            HStack(spacing: 10) {
                Spacer()
                UIOutlineButton(title: "Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                UIPrimaryButton(title: "Добавить", action: add)
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.4 : 1)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.uiPaper)
        .onAppear { fieldFocused = true }
        .task(id: trimmed) { await refreshSuggestions(for: trimmed) }
    }

    /// Транслитерация сразу, модель после паузы в наборе. Устаревший ответ отбрасывается.
    private func refreshSuggestions(for value: String) async {
        let suggester = VariantSuggester(checker: SpellCommonWordChecker.shared, llm: VariantSuggester.currentLLM())
        draft.applySuggestions(suggester.instant(for: value))
        guard !value.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        let full = await suggester.suggest(for: value)
        guard !Task.isCancelled, value == trimmed else { return }
        draft.applySuggestions(full)
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        store.addEntry(spelling: trimmed, variants: draft.allVariants, source: .manual)
        dismiss()
    }
}

// MARK: - Запись слова 🎙

/// Кнопка «Произнести» с индикатором уровня. Результат всегда подтверждает пользователь.
struct WordProbeControl: View {
    let spelling: String
    let onSave: (String) -> Void

    @StateObject private var probe = WordProbe()
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, listening
        case result(DictionaryScreenLogic.ProbeResult)
    }

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .idle:
                probeButton(title: "Произнести", icon: "mic", action: start)
                    .disabled(spelling.isEmpty)
                    .opacity(spelling.isEmpty ? 0.4 : 1)
            case .listening:
                Button(action: stop) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.uiEmber)
                        Text("Скажите слово")
                            .foregroundColor(.uiInk)
                        LevelBar(level: probe.level)
                    }
                    .font(.ui(.footnote, weight: .medium))
                }
                .buttonStyle(.plain)
            case .result(.heard(let text)):
                Text("Услышал: «\(text)»")
                    .font(.ui(.footnote, weight: .medium))
                    .foregroundColor(.uiInk)
                probeButton(title: "Сохранить", icon: nil) {
                    onSave(text)
                    phase = .idle
                }
                probeButton(title: "Ещё раз", icon: nil, action: start)
            case .result(let result):
                Text(message(for: result))
                    .font(.ui(.footnote))
                    .foregroundColor(.uiMidGray)
                probeButton(title: "Ещё раз", icon: nil, action: start)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .onDisappear { probe.cancel() }
        .onChange(of: spelling) { _ in
            if phase != .idle { stop() }
        }
    }

    private func message(for result: DictionaryScreenLogic.ProbeResult) -> LocalizedStringKey {
        switch result {
        case .justTheWord: return "Скажите только слово"
        case .alreadyRecognized: return "Уже распознаётся верно"
        case .notHeard, .heard: return "Не расслышал"
        }
    }

    private func start() {
        guard !spelling.isEmpty else { return }
        phase = .listening
        probe.start(spelling: spelling) { outcome in
            phase = .result(DictionaryScreenLogic.probeResult(outcome))
        }
    }

    private func stop() {
        probe.cancel()
        phase = .idle
    }

    private func probeButton(title: LocalizedStringKey, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.ui(.caption, weight: .semibold))
                }
                Text(title)
                    .font(.ui(.footnote, weight: .medium))
            }
            .foregroundColor(.uiInk)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(Color.uiCanvas)
            .cornerRadius(UIRadius.sm)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
    }
}

/// Уровень входного сигнала от -60 до 0 дБ.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        let fraction = CGFloat(min(max((level + 60) / 60, 0), 1))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.uiHairline)
            Capsule().fill(Color.uiSuccess).frame(width: 80 * fraction)
        }
        .frame(width: 80, height: 4)
        .animation(.linear(duration: 0.08), value: fraction)
    }
}

// MARK: - Общие элементы

/// Вариант с крестиком удаления.
struct VariantChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.ui(.footnote))
                .foregroundColor(.uiInkSoft)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.ui(.micro, weight: .bold))
                    .foregroundColor(.uiMidGray)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Color.uiCanvas)
        .cornerRadius(UIRadius.xs)
        .overlay(RoundedRectangle(cornerRadius: UIRadius.xs).stroke(Color.uiHairline, lineWidth: 1))
    }
}

/// Перенос элементов по строкам.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

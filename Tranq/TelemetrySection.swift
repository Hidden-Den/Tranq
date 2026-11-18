import SwiftUI

/// Телеметрия внешнего API в разделе провайдера: инструмент отладки.
/// Свёрнута по умолчанию, состояние между запусками не хранится.
struct TelemetryDisclosure: View {
    @ObservedObject private var telemetry = CleanupTelemetry.shared
    @ObservedObject private var provider = AIProviderStore.shared
    @State private var isExpanded = false

    private static let recentCount = 5

    private var model: String { provider.config.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Color.uiHairline).frame(height: 1)

            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.ui(.micro, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Телеметрия")
                        .font(.ui(.footnote, weight: .medium))
                    Spacer()
                }
                .foregroundColor(.uiMidGray)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded { details }
        }
    }

    @ViewBuilder private var details: some View {
        if telemetry.records.isEmpty && telemetry.totals.isEmpty {
            Text("Пока нет запросов")
                .font(.ui(.footnote))
                .foregroundColor(.uiMidGray)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                currentModel
                allModels
                recent
                UIOutlineButton(title: "Сбросить") { telemetry.reset() }
            }
        }
    }

    // MARK: - Активная модель

    private var currentModel: some View {
        let totals = telemetry.totals[model] ?? ModelTotals(requests: 0, failures: 0, inputTokens: 0, outputTokens: 0)
        let estimated = totals.estimatedRequests > 0
        return VStack(alignment: .leading, spacing: 6) {
            if !model.isEmpty {
                Text(verbatim: model)
                    .font(.ui(.caption, weight: .bold))
                    .foregroundColor(.uiInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            statRow("Запросов", TelemetryFormat.count(totals.requests))
            statRow("Отказов", TelemetryFormat.count(totals.failures))
            statRow("Входящих", TelemetryFormat.count(totals.inputTokens), estimated: estimated)
            statRow("Исходящих", TelemetryFormat.count(totals.outputTokens), estimated: estimated)
            statRow("Первый токен", TelemetryFormat.seconds(telemetry.averageFirstToken(model: model)))
            statRow("Ответ", TelemetryFormat.seconds(telemetry.averageTotal(model: model)))
        }
    }

    private func statRow(_ title: LocalizedStringKey, _ value: String, estimated: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.ui(.footnote))
                .foregroundColor(.uiMidGray)
            Spacer()
            if estimated {
                Text("оценка")
                    .font(.ui(.caption))
                    .foregroundColor(.uiMidGray)
            }
            Text(verbatim: value)
                .font(.ui(.footnote, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.uiInk)
        }
    }

    // MARK: - Все модели

    private var allModels: some View {
        let input = telemetry.totals.values.reduce(0) { $0 + $1.inputTokens }
        let output = telemetry.totals.values.reduce(0) { $0 + $1.outputTokens }
        return HStack(spacing: 8) {
            Text("Все модели")
                .font(.ui(.footnote, weight: .medium))
                .foregroundColor(.uiInk)
            Spacer()
            Text(verbatim: TelemetryFormat.tokens(input: input, output: output, estimated: telemetry.totals.values.contains { $0.estimatedRequests > 0 }))
                .font(.ui(.footnote, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.uiInk)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.uiHairline).frame(height: 1) }
    }

    // MARK: - Последние запросы

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Последние")
                .font(.ui(.caption, weight: .bold))
                .foregroundColor(.uiMidGray)
            ForEach(Array(telemetry.records.prefix(Self.recentCount).enumerated()), id: \.offset) { _, record in
                recordRow(record)
            }
        }
    }

    private func recordRow(_ record: TelemetryRecord) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: record.outcome))
                .frame(width: 6, height: 6)
            Text(verbatim: record.model)
                .font(.ui(.footnote))
                .foregroundColor(.uiInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch record.outcome {
            case .success: EmptyView()
            case .timeout: Text("таймаут").font(.ui(.caption)).foregroundColor(.uiMidGray)
            case .error: Text("ошибка").font(.ui(.caption)).foregroundColor(.uiMidGray)
            }
            Text(verbatim: TelemetryFormat.tokens(input: record.inputTokens, output: record.outputTokens, estimated: record.estimated))
                .font(.ui(.footnote))
                .monospacedDigit()
                .foregroundColor(.uiMidGray)
            Text(verbatim: TelemetryFormat.seconds(record.totalSeconds))
                .font(.ui(.footnote))
                .monospacedDigit()
                .foregroundColor(.uiMidGray)
        }
    }

    private func color(for outcome: TelemetryOutcome) -> Color {
        switch outcome {
        case .success: return .uiSuccess
        case .timeout: return .uiWarn
        case .error: return .uiEmber
        }
    }
}

/// Числа телеметрии: секунды с одним знаком, токены с разделителем тысяч.
enum TelemetryFormat {
    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(String(localized: "с"))"
    }

    /// Пара «входящие → исходящие». Локальная модель токенов не сообщает: вместо нулей прочерк.
    static func tokens(input: Int, output: Int, estimated: Bool) -> String {
        guard input > 0 || output > 0 else { return "—" }
        return "\(estimated ? "≈ " : "")\(count(input)) → \(count(output))"
    }
}

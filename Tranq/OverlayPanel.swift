import SwiftUI
import AppKit

class OverlayPanelManager {
    static let shared = OverlayPanelManager()
    private var panel: NSPanel?
    private var pendingHideWorkItem: DispatchWorkItem?
    
    func showOverlay(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil
            AudioCapture.shared.isSuccessDone = false
            
            if self.panel == nil {
                let newPanel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: OverlayMetrics.panelWidth, height: 60),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                newPanel.isOpaque = false
                newPanel.backgroundColor = .clear
                newPanel.hasShadow = false
                newPanel.appearance = NSApp.effectiveAppearance
                newPanel.hidesOnDeactivate = false
                newPanel.isReleasedWhenClosed = false
                newPanel.level = .screenSaver
                newPanel.isFloatingPanel = true
                newPanel.ignoresMouseEvents = true
                newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                
                let view = FloatingWidgetView()
                let hostingView = NSHostingView(rootView: view)
                hostingView.wantsLayer = true
                hostingView.layer?.backgroundColor = NSColor.clear.cgColor
                hostingView.layer?.isOpaque = false
                
                newPanel.contentView = hostingView
                self.panel = newPanel
            }
            
            // Тема могла смениться, пока панель жила скрытой.
            self.panel?.appearance = NSApp.effectiveAppearance

            if let screen = NSScreen.main {
                let panelWidth = OverlayMetrics.panelWidth
                let x = screen.frame.midX - (panelWidth / 2.0)
                let targetY = screen.visibleFrame.maxY - 44
                
                self.panel?.alphaValue = 0.0
                self.panel?.setFrameOrigin(NSPoint(x: x, y: targetY + 10))
                self.panel?.orderFrontRegardless()
                
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel?.animator().alphaValue = 1.0
                    self.panel?.animator().setFrameOrigin(NSPoint(x: x, y: targetY))
                }
            }
            
            completion?()
        }
    }
    
    func showWarning(message: String) {
        DispatchQueue.main.async {
            self.pendingHideWorkItem?.cancel()
            AudioCapture.shared.warningMessage = message
            SoundEffect.playWarning()
            self.showOverlay {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.hideOverlay()
                }
                self.pendingHideWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
            }
        }
    }
    
    func scheduleHide(after delay: Double) {
        DispatchQueue.main.async {
            self.pendingHideWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.hideOverlay() }
            self.pendingHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
    
    func hideOverlay() {
        DispatchQueue.main.async {
            self.pendingHideWorkItem?.cancel()
            self.pendingHideWorkItem = nil
            
            guard let panel = self.panel else { return }
            let currentFrame = panel.frame
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0.0
                panel.animator().setFrameOrigin(NSPoint(x: currentFrame.minX, y: currentFrame.minY + 6))
            }) {
                panel.orderOut(nil)
                AudioCapture.shared.warningMessage = nil
                AudioCapture.shared.isSuccessDone = false
                AudioCapture.shared.isSynthesizingThought = false
                AudioCapture.shared.hudStatusMessage = nil
            }
        }
    }

    func keepFront() {
        guard let panel = self.panel, panel.alphaValue > 0, !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }
}

/// Размеры плавающего окошка диктовки. Плашка меряется по содержимому,
/// панель заведомо шире, поэтому ничего не обрезается.
enum OverlayMetrics {
    /// Ширина панели под самую длинную плашку.
    static let panelWidth: CGFloat = 520
    /// Высота плашки.
    static let height: CGFloat = 38
    /// Скругление плашки по шкале проекта.
    static let radius: CGFloat = UIRadius.md
    /// Боковые отступы содержимого.
    static let inset: CGFloat = 14
    /// Высота полос уровня.
    static let barHeight: CGFloat = 16
    /// Дальше метка режима обрезается по многоточию.
    static let labelMaxWidth: CGFloat = 220
}

/// Цвета плашки. Поверхность плотная, а не стеклянная: под окном может быть
/// любой фон, и текст должен читаться и в светлой теме, и в тёмной.
enum OverlayPalette {
    static let surface = Color.dynamic(light: "#ffffff", dark: "#1d1e22")
    static let border = Color.dynamic(light: "#d9d9de", dark: "#3a3b42")
    /// Полосы уровня: монохром, разницу несёт высота.
    static let bar = Color.dynamic(light: "#52525b", dark: "#d4d4d8")
    static let recording = Color.dynamic(light: "#047857", dark: "#34d399")
    static let processing = Color.dynamic(light: "#4338ca", dark: "#818cf8")
    static let synthesis = Color.dynamic(light: "#7e22ce", dark: "#c084fc")
    static let warning = Color.dynamic(light: "#b45309", dark: "#fbbf24")
}

/// Плашка диктовки: спокойная поверхность, волосяная граница, без свечения.
struct FloatingWidgetView: View {
    @ObservedObject var audioCapture = AudioCapture.shared
    @State private var isAppeared = false

    var body: some View {
        content
            .padding(.horizontal, OverlayMetrics.inset)
            .frame(height: OverlayMetrics.height)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                let shape = RoundedRectangle(cornerRadius: OverlayMetrics.radius, style: .continuous)
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(OverlayPalette.surface.opacity(0.88))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: OverlayMetrics.radius, style: .continuous)
                    .strokeBorder(OverlayPalette.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 3)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: stateKey)
            .opacity(isAppeared ? 1 : 0)
            .offset(y: isAppeared ? 0 : -6)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) { isAppeared = true }
            }
            .onDisappear { isAppeared = false }
            .frame(width: OverlayMetrics.panelWidth, height: 60)
    }

    @ViewBuilder
    private var content: some View {
        if let warningText = audioCapture.warningMessage {
            OverlayStatusRow(dot: OverlayPalette.warning, text: warningText)
        } else if !audioCapture.isRecording && audioCapture.isSynthesizingThought {
            OverlayStatusRow(dot: OverlayPalette.synthesis, text: synthesisLabel, pulses: true)
        } else if audioCapture.transcribedText == String(localized: "Расшифровка...") {
            OverlayStatusRow(dot: OverlayPalette.processing, text: String(localized: "Расшифровка"), pulses: true)
        } else if audioCapture.isSuccessDone {
            OverlaySuccessRow(text: audioCapture.hudStatusMessage)
        } else {
            RecordingLevelView(modeLabel: audioCapture.modeLabel)
        }
    }

    private var synthesisLabel: String {
        VoiceIntelligenceSettings.shared.engine == .airGapped
            ? String(localized: "Синтез мысли SLM")
            : String(localized: "Синтез мысли")
    }

    /// Ключ состояния: по нему плашка плавно меняет ширину.
    private var stateKey: String {
        if let warning = audioCapture.warningMessage { return "warn:\(warning)" }
        if !audioCapture.isRecording && audioCapture.isSynthesizingThought { return "synth" }
        if audioCapture.transcribedText == String(localized: "Расшифровка...") { return "decode" }
        if audioCapture.isSuccessDone { return "done:\(audioCapture.hudStatusMessage ?? "")" }
        return "rec:\(audioCapture.modeLabel)"
    }
}

/// Точка состояния. Пульсирует только пока идёт работа.
private struct OverlayDot: View {
    let color: Color
    var pulses: Bool = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// Строка «точка и текст»: предупреждение, расшифровка, синтез.
private struct OverlayStatusRow: View {
    let dot: Color
    let text: String
    var pulses: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            OverlayDot(color: dot, pulses: pulses)
            Text(text)
                .font(.ui(.body, weight: .medium))
                .foregroundColor(Color.uiInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Готово: галочка и, если есть, куда вставлено.
private struct OverlaySuccessRow: View {
    let text: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.ui(.body, weight: .semibold))
                .foregroundColor(OverlayPalette.recording)
            if let text {
                Text(text)
                    .font(.ui(.body, weight: .medium))
                    .foregroundColor(Color.uiInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Таймер, метка режима и уровень записи. Отдельное представление, чтобы
/// обновления индикатора 20 раз в секунду не перерисовывали всю плашку.
private struct RecordingLevelView: View {
    @ObservedObject var meter = RecordingMeter.shared
    /// Пусто при обычной очистке; иначе имя правила.
    let modeLabel: String

    var body: some View {
        HStack(spacing: 8) {
            OverlayDot(color: OverlayPalette.recording, pulses: true)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(meter.elapsedSeconds)")
                    .font(.ui(.callout, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Color.uiInk)
                Text(String(localized: "с"))
                    .font(.ui(.footnote, weight: .medium))
                    .foregroundColor(Color.uiMidGray)
            }
            .lineLimit(1)
            .fixedSize()

            if !modeLabel.isEmpty {
                Rectangle()
                    .fill(OverlayPalette.border)
                    .frame(width: 1, height: 16)

                Text(modeLabel)
                    .font(.ui(.footnote, weight: .medium))
                    .foregroundColor(Color.uiMidGray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: OverlayMetrics.labelMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LevelBars(samples: meter.samples)
                .padding(.leading, 2)
        }
    }
}

/// Монохромные полосы уровня. Цвет один, разницу несёт только высота.
private struct LevelBars: View {
    let samples: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<RecordingMeter.barCount, id: \.self) { i in
                let sampleVal = i < samples.count ? samples[i] : RecordingMeter.floorLevel
                RoundedRectangle(cornerRadius: 1)
                    .fill(OverlayPalette.bar.opacity(0.65))
                    .frame(width: 2, height: max(2, CGFloat(sampleVal) * OverlayMetrics.barHeight))
                    .animation(.spring(response: 0.12, dampingFraction: 0.55), value: sampleVal)
            }
        }
        .frame(height: OverlayMetrics.barHeight)
        .fixedSize()
    }
}

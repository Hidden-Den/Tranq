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
                    contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
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
            
            if let screen = NSScreen.main {
                let panelWidth: CGFloat = 240
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

struct RotatingGlowBorder: View {
    var body: some View {
        GeometryReader { geo in
            let size = max(geo.size.width, geo.size.height) * 2.0
            TimelineView(.animation) { timeline in
                let angle = (timeline.date.timeIntervalSince1970 * 360.0 / 1.5).truncatingRemainder(dividingBy: 360)
                ZStack {
                    AngularGradient(
                        gradient: Gradient(colors: [Color.uiAI, Color.uiProcessing, Color.uiInfoLight, Color.uiSuccess, Color.uiAI]),
                        center: .center
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(angle))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .mask(Capsule().stroke(lineWidth: 1.5))
            }
        }
    }
}

struct SuccessCheckView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.uiSuccessLight.opacity(0.45), lineWidth: 2)
                .frame(width: 24, height: 24)
            Image(systemName: "checkmark")
                .font(.ui(.body, weight: .bold))
                .foregroundColor(.white)
        }
        .scaleEffect(appeared ? 1.0 : 0.2)
        .offset(y: appeared ? 0 : -10)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.4, dampingFraction: 0.52)) {
                appeared = true
            }
        }
    }
}

struct FloatingWidgetView: View {
    @ObservedObject var audioCapture = AudioCapture.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isAppeared = false
    
    let greenGradient = LinearGradient(colors: [Color.uiSuccessLight, Color.uiSuccessDeep], startPoint: .top, endPoint: .bottom)
    let purpleGradient = LinearGradient(colors: [Color.uiAI, Color.uiProcessing], startPoint: .top, endPoint: .bottom)
    let glassBorderGradient = LinearGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom)
    
    var body: some View {
        ZStack {
            Color.clear
            
            Capsule()
                .fill(getGlowColor())
                .frame(width: getWidth() - 10, height: 28)
                .blur(radius: 12)
                .opacity(0.4)
            
            HStack(alignment: .center, spacing: 10) {
                if let warningText = audioCapture.warningMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.ui(.body, weight: .bold))
                            .foregroundColor(Color.uiAmber)
                        Text(warningText)
                            .font(.ui(.footnote, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                } else if !audioCapture.isRecording && audioCapture.isSynthesizingThought {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.ui(.body, weight: .bold))
                            .foregroundColor(Color.uiAI)
                        let synthLabel = VoiceIntelligenceSettings.shared.engine == .airGapped ? String(localized: "Синтез мысли SLM...") : String(localized: "Синтез мысли...")
                        Text(synthLabel)
                            .font(.ui(.footnote, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                } else if audioCapture.transcribedText == String(localized: "Расшифровка...") {
                    HStack(spacing: 2.0) {
                        TimelineView(.animation) { timeline in
                            let time = timeline.date.timeIntervalSince1970 * 4.5
                            HStack(spacing: 2.0) {
                                ForEach(0..<18, id: \.self) { i in
                                    let height = sin(time + Double(i) * 0.5) * 7 + 11
                                    RoundedRectangle(cornerRadius: 1).fill(purpleGradient).frame(width: 2.0, height: height)
                                }
                            }
                        }
                    }
                } else if audioCapture.isSuccessDone {
                    if let status = audioCapture.hudStatusMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.ui(.footnote, weight: .bold))
                                .foregroundColor(Color.uiSuccessLight)
                            Text(status)
                                .font(.ui(.footnote, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .transition(.opacity)
                    } else {
                        SuccessCheckView()
                            .transition(.opacity)
                    }
                } else {
                    RecordingLevelView(timerColor: timerColor, barGradient: greenGradient, modeLabel: audioCapture.modeLabel)
                }
            }
            .padding(.horizontal, 14)
            .frame(width: getWidth(), height: 36)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Group {
                    if audioCapture.transcribedText == String(localized: "Расшифровка...") || (!audioCapture.isRecording && audioCapture.isSynthesizingThought) {
                        RotatingGlowBorder()
                    } else if audioCapture.warningMessage != nil {
                        Capsule().stroke(Color.uiAmber.opacity(0.6), lineWidth: 1.2)
                    } else if audioCapture.isSuccessDone {
                        Capsule().stroke(Color.uiSuccessLight.opacity(0.75), lineWidth: 1.2)
                    } else {
                        Capsule().stroke(glassBorderGradient, lineWidth: 1.0)
                    }
                }
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: getWidth())
        }
        .scaleEffect(isAppeared ? 1.0 : 0.65)
        .offset(y: isAppeared ? 0 : -14)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.55)) {
                isAppeared = true
            }
        }
        .onDisappear {
            isAppeared = false
        }
        .frame(width: 240, height: 60)
    }
    
    private func getWidth() -> CGFloat {
        if audioCapture.warningMessage != nil { return 210 }
        if !audioCapture.isRecording && audioCapture.isSynthesizingThought { return 180 }
        if audioCapture.isRecording { return audioCapture.modeLabel.isEmpty ? 200 : 236 }
        if audioCapture.isSuccessDone {
            return audioCapture.hudStatusMessage != nil ? 180 : 150
        }
        return 130
    }
    
    private func getGlowColor() -> Color {
        if audioCapture.warningMessage != nil { return Color.uiAmber }
        if !audioCapture.isRecording && audioCapture.isSynthesizingThought { return Color.uiAI }
        if audioCapture.transcribedText == String(localized: "Расшифровка...") { return Color.uiProcessing }
        if audioCapture.isSuccessDone { return Color.uiSuccess }
        return Color.uiSuccess
    }

    private var timerColor: Color {
        Color.uiSuccessText
    }
}

/// Таймер и полосы громкости во время записи. Отдельное представление, чтобы
/// обновления индикатора 20 раз в секунду не перерисовывали весь оверлей.
private struct RecordingLevelView: View {
    @ObservedObject var meter = RecordingMeter.shared
    let timerColor: Color
    let barGradient: LinearGradient
    /// Пусто при обычной очистке; иначе «Промпт» или имя правила.
    let modeLabel: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.uiSuccess)
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.uiSuccess.opacity(0.8), radius: 3, x: 0, y: 0)

                Text(meter.elapsedText)
                    .font(.ui(.body, weight: .bold, design: .monospaced))
                    .foregroundColor(timerColor)
                    .shadow(color: timerColor.opacity(0.55), radius: 2, x: 0, y: 0)
            }

            if !modeLabel.isEmpty {
                Text(modeLabel)
                    .font(.ui(.caption, weight: .semibold))
                    .foregroundColor(Color.uiAI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            HStack(spacing: 2.0) {
                ForEach(0..<RecordingMeter.barCount, id: \.self) { i in
                    let sampleVal = i < meter.samples.count ? meter.samples[i] : RecordingMeter.floorLevel

                    RoundedRectangle(cornerRadius: 1)
                        .fill(barGradient)
                        .frame(width: 2.0, height: CGFloat(sampleVal) * 22)
                        .animation(.spring(response: 0.12, dampingFraction: 0.55), value: sampleVal)
                }
            }
        }
    }
}

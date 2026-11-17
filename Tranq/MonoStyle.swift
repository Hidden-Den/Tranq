import SwiftUI
import AppKit

// MARK: - Тактильный стиль кнопок
struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Hex Initializer for NSColor
extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

// MARK: - Hex & Dynamic Initializers for SwiftUI Color
extension Color {
    init(hex: String) {
        self.init(NSColor(hex: hex))
    }
    
    static func dynamic(light: String, dark: String) -> Color {
        return Color(NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(hex: dark)
            } else {
                return NSColor(hex: light)
            }
        })
    }
    
    // MARK: - Shadcn / Vercel Dynamic Tokens
    static let uiCanvas = dynamic(light: "#ffffff", dark: "#000000")
    static let uiPaper = dynamic(light: "#f8f8fa", dark: "#141417")
    static let uiSidebar = dynamic(light: "#ffffff", dark: "#000000")
    static let uiInk = dynamic(light: "#0a0a0a", dark: "#fafafa")
    static let uiInkSoft = dynamic(light: "#171717", dark: "#d4d4d8")
    static let uiMidGray = dynamic(light: "#737373", dark: "#a1a1aa")
    static let uiHairline = dynamic(light: "#e5e5e5", dark: "#27272a")
    static let uiWarn = dynamic(light: "#FF9F0A", dark: "#F59E0B")
    static let uiEmber = dynamic(light: "#e7000b", dark: "#ef4444")
    

    // MARK: - Семантические цвета состояний
    // Акценты используются точечно: успех, предупреждение, работа ИИ, обработка, ссылки.
    static let uiSuccess = Color(hex: "#10B981")
    static let uiSuccessLight = Color(hex: "#34D399")
    static let uiSuccessDeep = Color(hex: "#059669")
    static let uiSuccessText = dynamic(light: "#047857", dark: "#10B981")
    static let uiAmber = Color(hex: "#F59E0B")
    static let uiAI = Color(hex: "#C084FC")
    static let uiProcessing = Color(hex: "#6366F1")
    static let uiInfoLight = Color(hex: "#38BDF8")
}

// MARK: - Шкала шрифтов
/// Девять ступеней вместо произвольных размеров. Минимум 10 pt.
enum UITextSize: CGFloat {
    case micro = 10
    case caption = 11
    case footnote = 12
    case body = 13
    case callout = 15
    case headline = 17
    case title = 20
    case largeTitle = 26
    case display = 30
}

extension Font {
    static func ui(_ size: UITextSize, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard BrandFonts.usesInter(for: design) else {
            return .system(size: size.rawValue, weight: weight, design: design)
        }
        return .custom(BrandFonts.interName(for: weight), size: size.rawValue)
    }
}

// MARK: - Шкала скруглений
enum UIRadius {
    /// Мелкие плашки, бейджи, полосы индикаторов
    static let xs: CGFloat = 4
    /// Кнопки, поля ввода, пункты меню
    static let sm: CGFloat = 8
    /// Блоки внутри карточек, поповеры
    static let md: CGFloat = 12
    /// Крупные кнопки-пилюли, панели
    static let lg: CGFloat = 18
    /// Карточки и модальные окна
    static let xl: CGFloat = 24
}

// MARK: - Базовые ТАКТИЛЬНЫЕ UI Компоненты

struct UICard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(20)
            .background(RoundedRectangle(cornerRadius: UIRadius.xl, style: .continuous).fill(Color.uiPaper))
            .overlay(RoundedRectangle(cornerRadius: UIRadius.xl, style: .continuous).stroke(Color.uiHairline, lineWidth: 1))
    }
}

struct UIOutlineButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(.body, weight: .medium))
                .foregroundColor(.uiInk)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.uiPaper)
                .cornerRadius(UIRadius.lg)
                .overlay(RoundedRectangle(cornerRadius: UIRadius.lg).stroke(Color.uiHairline, lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle()) // ТАКТИЛЬНЫЙ СТИЛЬ
    }
}

struct UIDestructiveButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(.body, weight: .medium))
                .foregroundColor(.uiEmber)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.uiEmber.opacity(0.1))
                .cornerRadius(UIRadius.lg)
                .overlay(RoundedRectangle(cornerRadius: UIRadius.lg).stroke(Color.uiEmber.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle()) // ТАКТИЛЬНЫЙ СТИЛЬ
    }
}

struct UIPrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(.body, weight: .medium))
                .foregroundColor(Color.dynamic(light: "#ffffff", dark: "#000000"))
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.uiInk)
                .cornerRadius(UIRadius.lg)
        }
        .buttonStyle(TactileButtonStyle()) // ТАКТИЛЬНЫЙ СТИЛЬ
    }
}

struct UIBadge: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(.micro, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(.uiMidGray)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(Color.uiCanvas)
            .cornerRadius(UIRadius.lg)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.lg).stroke(Color.uiHairline, lineWidth: 1))
    }
}

// MARK: - Шиммер (бегущий блик для скелетонов)

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.5), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: geo.size.width * (phase * 1.8 - 0.5))
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

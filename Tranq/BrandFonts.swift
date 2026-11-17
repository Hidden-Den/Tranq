import SwiftUI
import CoreText

/// Шрифты бренда: Inter для интерфейса и Knewave для названия.
/// Файлы лежат в бандле и регистрируются кодом при запуске. Если шрифта нет,
/// SwiftUI молча берёт системный, текст остаётся читаемым.
enum BrandFonts {
    static let knewaveName = "Knewave-Regular"

    private static let interRegular = "Inter-Regular"
    private static let interMedium = "Inter-Medium"
    private static let interSemiBold = "Inter-SemiBold"
    private static let interBold = "Inter-Bold"

    /// Имя статического начертания Inter для веса: лёгкие веса уходят в Regular, тяжёлые в Bold.
    static func interName(for weight: Font.Weight) -> String {
        switch weight {
        case .medium: return interMedium
        case .semibold: return interSemiBold
        case .bold, .heavy, .black: return interBold
        default: return interRegular
        }
    }

    /// Inter заменяет только обычный шрифт. Моноширинный и прочие дизайны остаются системными.
    static func usesInter(for design: Font.Design) -> Bool {
        design == .default
    }

    /// Регистрирует все `.ttf` из подпапки `Fonts` и из корня ресурсов, если Xcode сложил их плоско.
    /// Возвращает число доступных шрифтов; повторная регистрация не считается ошибкой.
    @discardableResult
    static func registerAll(in bundle: Bundle = .main) -> Int {
        var urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        var seen = Set(urls.map(\.lastPathComponent))
        for url in bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        where seen.insert(url.lastPathComponent).inserted {
            urls.append(url)
        }
        var registered = 0
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered += 1
            } else if let code = error?.takeRetainedValue(),
                      CFErrorGetCode(code) == CTFontManagerError.alreadyRegistered.rawValue {
                registered += 1
            }
        }
        return registered
    }
}

extension Font {
    /// Название приложения. Только для имени и буквы Q, не для основного текста.
    static func brand(_ size: CGFloat) -> Font {
        .custom(BrandFonts.knewaveName, size: size)
    }
}

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    
    var currentVersionStr: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "v\(ver)"
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // 1. ИКОНКА И ЗАГОЛОВОК
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                
                Text("Tranq")
                    .font(.brand(30))
                    .foregroundColor(.uiInk)
                
                UIBadge(text: currentVersionStr)
            }
            
            // 2. ОПИСАНИЕ
            Text("Голосовая диктовка для macOS. Речь распознаётся на вашем Mac, без передачи данных посторонним.")
                .font(.ui(.footnote))
                .multilineTextAlignment(.center)
                .foregroundColor(.uiMidGray)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            
            Divider().background(Color.uiHairline)
            
            // 3. ТЕХНИЧЕСКИЙ СТЕК
            HStack(spacing: 8) {
                TechBadge(text: "GIGAAM V3")
                TechBadge(text: "APPLE SILICON")
                TechBadge(text: "CORE ML")
            }
            
            Divider().background(Color.uiHairline)
            
            // 4. КНОПКИ
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    AboutLinkButton(title: "GitHub", icon: "terminal.fill") {
                        openURL(URL(string: "https://github.com/Nuteres/Tranq")!)
                    }
                    AboutLinkButton(title: "Релизы", icon: "doc.text") {
                        openURL(URL(string: "https://github.com/Nuteres/Tranq/releases")!)
                    }
                }
            }
            
            Divider().background(Color.uiHairline)
            
            // 5. КНОПКА ЗАКРЫТИЯ
            HStack {
                Spacer()
                
                UIOutlineButton(title: "Закрыть") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Color.uiPaper)
    }
}

struct TechBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.ui(.micro, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.uiCanvas)
            .cornerRadius(UIRadius.sm)
            .overlay(RoundedRectangle(cornerRadius: UIRadius.sm).stroke(Color.uiHairline, lineWidth: 1))
            .foregroundColor(.uiInk)
    }
}

struct AboutLinkButton: View {
    let title: LocalizedStringKey
    let icon: String
    var isEnabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            if isEnabled { action() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.ui(.caption, weight: .medium))
                Text(title)
                    .font(.ui(.footnote, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.uiCanvas)
            .cornerRadius(UIRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: UIRadius.md)
                    .stroke(isEnabled ? Color.uiHairline : Color.uiHairline.opacity(0.35), lineWidth: 1)
            )
            .foregroundColor(isEnabled ? .uiInk : .uiMidGray)
            .opacity(isEnabled ? 1.0 : 0.4)
        }
        .disabled(!isEnabled)
        .buttonStyle(TactileButtonStyle())
    }
}

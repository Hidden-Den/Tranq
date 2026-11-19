import SwiftUI
import AppKit

/// Заглушка запертой истории. О содержимом молчит: ни счётчика записей, ни точек непрочитанного.
/// Подтверждение личности просит только кнопка, при появлении экрана диалога нет.
struct HistoryLockedView: View {
    let state: HistoryLockState
    let onUnlock: () -> Void
    let onErase: () -> Void

    @State private var confirmingErase = false

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            if state == .keyUnavailable {
                VStack(spacing: 6) {
                    Text("История не читается на этом Mac")
                        .font(.ui(.headline, weight: .semibold))
                        .foregroundColor(.uiInk)
                    Text("Ключ остался на прежнем Mac")
                        .font(.ui(.body))
                        .foregroundColor(.uiMidGray)
                }
                .multilineTextAlignment(.center)
                UIDestructiveButton(title: "Стереть историю") {
                    confirmingErase = true
                }
            } else {
                Text("История заперта")
                    .font(.ui(.headline, weight: .semibold))
                    .foregroundColor(.uiInk)
                UIPrimaryButton(title: "Разблокировать", action: onUnlock)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Тот же текст, что у стирания в настройках: история удаляется только по согласию
        .alert("Стереть всю историю?", isPresented: $confirmingErase) {
            Button("Отмена", role: .cancel) { }
            Button("Стереть", role: .destructive, action: onErase)
        } message: { Text("Все сохраненные транскрипции будут удалены безвозвратно. Это действие нельзя отменить.") }
    }
}

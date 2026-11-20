import SwiftUI
import AppKit

/// Заглушка запертой истории. О содержимом молчит: ни счётчика записей, ни точек непрочитанного.
/// Подтверждение личности просит только кнопка, при появлении экрана диалога нет.
struct HistoryLockedView: View {
    enum Action: Equatable { case unlock, erase }

    let state: HistoryLockState
    /// Ключ на месте, но не прочитался: разлочку можно повторить.
    var keyExists = false
    /// Последнее стирание убрало не всё.
    var eraseFailed = false
    let onUnlock: () -> Void
    let onErase: () -> Void

    /// Кнопки заглушки. «Не читается» с ключом на месте даёт повторить разлочку.
    static func actions(for state: HistoryLockState, keyExists: Bool) -> [Action] {
        switch state {
        case .keyUnavailable: keyExists ? [.unlock, .erase] : [.erase]
        default: [.unlock]
        }
    }

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
            } else {
                Text("История заперта")
                    .font(.ui(.headline, weight: .semibold))
                    .foregroundColor(.uiInk)
            }

            HStack(spacing: 12) {
                ForEach(Self.actions(for: state, keyExists: keyExists), id: \.self) { action in
                    switch action {
                    case .unlock:
                        UIPrimaryButton(title: "Разблокировать", action: onUnlock)
                    case .erase:
                        UIDestructiveButton(title: "Стереть историю") {
                            confirmingErase = true
                        }
                    }
                }
            }

            if eraseFailed {
                Text("Не всё удалось стереть")
                    .font(.ui(.caption))
                    .foregroundColor(.uiEmber)
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

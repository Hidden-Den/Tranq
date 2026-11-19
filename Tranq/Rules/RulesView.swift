import SwiftUI

/// Раздел бокового меню: тон текста по приложениям и сайтам.
struct RulesView: View {
    var body: some View {
        ScrollView {
            RulesSettingsSection()
                .padding(20)
        }
        .background(Color.uiCanvas)
    }
}

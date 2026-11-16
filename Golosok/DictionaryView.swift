import SwiftUI

/// Экран словаря. Временная заглушка до полноценного экрана.
struct DictionaryView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Словарь")
                .font(.largeTitle.weight(.bold))
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

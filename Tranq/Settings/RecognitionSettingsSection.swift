import SwiftUI

/// Раздел «Распознавание»: модель распознавания речи и состояние её загрузки.
struct RecognitionSettingsSection: View {
    @ObservedObject var models = ModelStore.shared

    var body: some View {
        SettingsPage {
            UICard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Языковая модель")
                            .font(.ui(.body, weight: .medium))
                            .foregroundColor(.uiInk)
                        Spacer()
                        UIDropdownPicker(selection: Binding(
                            get: { models.activeModelID },
                            set: { models.activeModelID = $0 }
                        ), options: ModelStore.catalog.map { m in
                            .init(LocalizedStringKey(m.name), value: m.id)
                        }, width: 200)
                    }

                    ActiveModelStatusRow()
                        .padding(.vertical, 4)

                    Divider().background(Color.uiHairline)

                    HStack {
                        Text("Аппаратное ускорение")
                            .font(.ui(.body, weight: .medium))
                            .foregroundColor(.uiInk)
                        Spacer()
                        Text("Apple Metal")
                            .font(.ui(.footnote))
                            .foregroundColor(.uiMidGray)
                    }
                }
            }
        }
    }
}

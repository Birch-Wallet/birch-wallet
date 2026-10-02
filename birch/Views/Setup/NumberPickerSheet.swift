import SwiftUI

struct NumberPickerSheet: View {
  let title: String
  let range: ClosedRange<Int>
  @Binding var selection: Int
  var onChange: ((Int) -> Void)?
  @Environment(\.dismiss) var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker(title, selection: Binding(
          get: { selection },
          set: { newValue in
            selection = newValue
            onChange?(newValue)
          }
        )) {
          ForEach(range, id: \.self) { num in
            Text("\(num)").tag(num)
          }
        }
        .pickerStyle(.wheel)
        .padding()

        Spacer()
      }
      .background(Color.hbBackground.ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
          .buttonStyle(HBBarButtonStyle(prominent: true))
        }
        .hbHidesGlassBackground()
      }
    }
    .presentationDetents([.height(300)])
    .presentationDragIndicator(.visible)
  }
}

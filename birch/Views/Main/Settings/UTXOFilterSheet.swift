import SwiftUI

private let logger = AppLog(.utxo)

/// Filter and sort options for the UTXO list. Changes apply live and persist
/// through the caller's AppStorage binding.
struct UTXOFilterSheet: View {
  @Binding var filter: UTXOFilter
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          section("Show") {
            filterToggle("Spendable", caption: "Unspent outputs available to send", isOn: $filter.showSpendable)
            HBDivider()
            filterToggle("Frozen", caption: "Unspent outputs excluded from coin selection", isOn: $filter.showFrozen)
            HBDivider()
            filterToggle("Spent", caption: "Outputs this wallet has already spent", isOn: $filter.showSpent)
          }

          section("Type") {
            filterToggle("Change Outputs", caption: "Hide to see only receive outputs", isOn: $filter.showChange)
          }

          section("Sort By") {
            ForEach(UTXOFilter.SortKey.allCases) { key in
              Button {
                guard filter.sort != key else { return }
                filter.sort = key
                filter.ascending = key.defaultAscending
              } label: {
                HStack {
                  Text(key.title)
                    .font(.hbBody())
                    .foregroundStyle(Color.hbTextPrimary)
                  Spacer()
                  if filter.sort == key {
                    Image(systemName: "checkmark")
                      .font(.system(size: 14, weight: .semibold))
                      .foregroundStyle(Color.hbBitcoinOrange)
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(filter.sort == key ? .isSelected : [])
              HBDivider()
            }

            Picker("Order", selection: $filter.ascending) {
              Text(filter.sort.directionTitle(ascending: filter.sort.defaultAscending))
                .tag(filter.sort.defaultAscending)
              Text(filter.sort.directionTitle(ascending: !filter.sort.defaultAscending))
                .tag(!filter.sort.defaultAscending)
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
          }
        }
        .padding(16)
      }
      .background(Color.hbBackground.ignoresSafeArea())
      .navigationTitle("Filter")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Reset") {
            filter = UTXOFilter()
          }
          .buttonStyle(HBBarButtonStyle())
          .disabled(filter == UTXOFilter())
        }
        .hbHidesGlassBackground()

        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
          .buttonStyle(HBBarButtonStyle(prominent: true))
        }
        .hbHidesGlassBackground()
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .birchSheet()
    .onDisappear {
      logger.info(
        "UTXO filter: spendable=\(filter.showSpendable) frozen=\(filter.showFrozen) "
          + "spent=\(filter.showSpent) change=\(filter.showChange) "
          + "sort=\(filter.sort.rawValue) ascending=\(filter.ascending)"
      )
    }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
        .padding(.horizontal, 4)

      VStack(alignment: .leading, spacing: 12) {
        content()
      }
      .hbCard()
    }
  }

  private func filterToggle(_ title: String, caption: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.hbBody())
          .foregroundStyle(Color.hbTextPrimary)
        Text(caption)
          .font(.hbBody(12))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .tint(Color.hbBitcoinOrange)
  }
}

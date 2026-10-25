import SwiftData
import SwiftUI

struct AddressListView: View {
  @State private var viewModel = AddressListViewModel()
  @Query private var walletLabels: [WalletLabel]

  var body: some View {
    VStack(spacing: 0) {
      Picker("Type", selection: $viewModel.selectedTab) {
        ForEach(AddressListViewModel.AddressTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      if viewModel.displayedAddresses.isEmpty {
        ContentUnavailableView(
          "No Addresses",
          systemImage: "number",
          description: Text("Addresses will appear after wallet refresh"),
        )
      } else {
        List(viewModel.displayedAddresses) { address in
          NavigationLink(destination: AddressDetailView(address: address.address, index: address.index)) {
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 12) {
                Text("#\(address.index)")
                  .font(.hbMono(12))
                  .foregroundStyle(Color.hbTextSecondary)
                  .frame(width: 36, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                  Text(address.address)
                    .font(.hbMono(12))
                    .foregroundStyle(Color.hbTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Spacer()

                Text(address.isUsed ? "Used" : "Unused")
                  .font(.hbLabel(10))
                  .foregroundStyle(address.isUsed ? Color.hbTextSecondary : Color.hbSuccess)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background((address.isUsed ? Color.hbTextSecondary : Color.hbSuccess).opacity(0.15))
                  .clipShape(Capsule())
              }

              if let addrLabel = addressLabel(for: address.address), !addrLabel.isEmpty {
                HStack(spacing: 4) {
                  Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                  Text(addrLabel)
                    .font(.hbBody(12))
                    .lineLimit(1)
                }
                .foregroundStyle(Color.hbInfo)
                .padding(.leading, 48)
              }
            }
          }
          .listRowBackground(Color.hbSurface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .background(Color.hbBackground)
    .navigationTitle("Addresses")
    .onAppear {
      if let profileId = BitcoinService.shared.currentProfile?.id {
        viewModel.loadAddresses(for: profileId)
      }
    }
  }

  private func addressLabel(for address: String) -> String? {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "addr" && $0.ref == address })?.label
  }
}

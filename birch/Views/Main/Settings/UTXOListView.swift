import SwiftData
import SwiftUI

struct UTXOListView: View {
  @State private var viewModel = UTXOListViewModel()
  @Environment(\.modelContext) private var modelContext
  @Query private var frozenUTXOs: [FrozenUTXO]
  @Query private var walletLabels: [WalletLabel]
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @AppStorage(Constants.fiatPrimaryKey) private var fiatPrimary = false

  private var isPrivate: Bool {
    BitcoinService.shared.currentProfile?.privacyMode ?? false
  }

  var body: some View {
    VStack(spacing: 0) {
      // Title
      Text("UTXOs")
        .font(.hbAmountLarge)
        .foregroundStyle(Color.hbTextPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)

      if viewModel.utxos.isEmpty {
        ContentUnavailableView(
          "No UTXOs",
          systemImage: "bitcoinsign.circle",
          description: Text("UTXOs will appear after refreshing your wallet")
        )
      } else {
        List(viewModel.utxos) { utxo in
          NavigationLink(destination: UTXODetailView(utxo: utxo)) {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                if isPrivate {
                  Text(Constants.privacyText())
                    .font(.hbMono(14))
                    .foregroundStyle(isFrozen(utxo) ? Color.hbTextSecondary : Color.hbTextPrimary)
                } else if fiatEnabled, fiatPrimary, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(utxo.amount) {
                  Text(fiatStr)
                    .font(.hbMono(14))
                    .foregroundStyle(isFrozen(utxo) ? Color.hbTextSecondary : Color.hbTextPrimary)
                } else {
                  Text(utxo.amount.formattedSats)
                    .font(.hbMono(14))
                    .foregroundStyle(isFrozen(utxo) ? Color.hbTextSecondary : Color.hbTextPrimary)
                }

                Spacer()

                if isFrozen(utxo) {
                  Text("Frozen")
                    .font(.hbLabel(10))
                    .foregroundStyle(Color.hbSteelBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.hbSteelBlue.opacity(0.15))
                    .clipShape(Capsule())
                }

                Text(utxo.isConfirmed ? "Confirmed" : "Unconfirmed")
                  .font(.hbLabel(10))
                  .foregroundStyle(utxo.isConfirmed ? Color.hbSuccess : Color.hbBitcoinOrange)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background((utxo.isConfirmed ? Color.hbSuccess : Color.hbBitcoinOrange).opacity(0.15))
                  .clipShape(Capsule())
              }

              HStack {
                if isPrivate {
                  Text(Constants.privacyText(length: 8))
                    .font(.hbMono(11))
                    .foregroundStyle(Color.hbTextSecondary)
                } else if let address = viewModel.address(for: utxo) {
                  Text(address.truncatedMiddle(leading: 10, trailing: 8))
                    .font(.hbMono(11))
                    .foregroundStyle(Color.hbTextSecondary)
                }

                Spacer()

                if let date = viewModel.bestDate(for: utxo) {
                  Text(date.smartRelativeString)
                    .font(.hbBody(11))
                    .foregroundStyle(Color.hbTextSecondary)
                }
              }

              HStack {
                Text(utxo.keychain == .external ? "Receive" : "Change")
                  .font(.hbLabel(10))
                  .foregroundStyle(Color.hbTextSecondary)

                Spacer()

                if let label = utxoLabel(for: utxo), !label.isEmpty {
                  HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                      .font(.system(size: 9))
                    Text(String(label.prefix(60)))
                      .font(.hbBody(11))
                      .lineLimit(1)
                  }
                  .foregroundStyle(Color.hbSteelBlue)
                }
              }
            }
            .opacity(isFrozen(utxo) ? 0.6 : 1.0)
          }
          .swipeActions(edge: .trailing) {
            if isFrozen(utxo) {
              Button {
                unfreezeUTXO(utxo)
              } label: {
                Label("Unfreeze", systemImage: "flame")
              }
              .tint(Color.hbBitcoinOrange)
            } else {
              Button {
                freezeUTXO(utxo)
              } label: {
                Label("Freeze", systemImage: "snowflake")
              }
              .tint(Color.hbSteelBlue)
            }
          }
          .listRowBackground(Color.hbSurface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .background(Color.hbBackground)
    .navigationTitle("")
    .onAppear {
      viewModel.loadUTXOs()
    }
    .onChange(of: BitcoinService.shared.currentProfile?.id) {
      viewModel.loadUTXOs()
    }
  }

  private func utxoLabel(for utxo: UTXOItem) -> String? {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "utxo" && $0.ref == utxo.id })?.label
  }

  private func isFrozen(_ utxo: UTXOItem) -> Bool {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return false }
    return frozenUTXOs.contains { $0.walletID == walletID && $0.outpoint == utxo.id }
  }

  private func freezeUTXO(_ utxo: UTXOItem) {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    modelContext.insert(FrozenUTXO(walletID: walletID, txid: utxo.txid, vout: utxo.vout))
    try? modelContext.save()
    AppLog(.utxo).info("Froze UTXO \(utxo.id) (\(utxo.amount) sats)")
  }

  private func unfreezeUTXO(_ utxo: UTXOItem) {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    let txid = utxo.txid
    let descriptor = FetchDescriptor<FrozenUTXO>(predicate: #Predicate {
      $0.walletID == walletID && $0.txid == txid
    })
    let outpoint = utxo.id
    if let frozen = (try? modelContext.fetch(descriptor))?.first(where: { $0.outpoint == outpoint }) {
      modelContext.delete(frozen)
      try? modelContext.save()
      AppLog(.utxo).info("Unfroze UTXO \(utxo.id) (\(utxo.amount) sats)")
    }
  }
}

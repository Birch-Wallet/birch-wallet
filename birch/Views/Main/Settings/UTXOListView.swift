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
  @AppStorage(Constants.utxoFilterKey) private var filter = UTXOFilter()
  @State private var showFilterSheet = false
  @Namespace private var filterNamespace

  private static let filterTransitionID = "utxoFilter"

  private var isPrivate: Bool {
    BitcoinService.shared.currentProfile?.privacyMode ?? false
  }

  private var walletID: UUID? {
    BitcoinService.shared.currentProfile?.id
  }

  var body: some View {
    // Amounts format from the Bitcoin unit setting; read it so a change redraws them
    let _ = denomination
    let frozen = frozenOutpoints
    let labels = labelsByRef
    let visible = filter.apply(
      to: viewModel.outputs,
      isFrozen: { frozen.contains($0.id) },
      label: { labels["utxo:\($0.id)"] },
      date: { viewModel.bestDate(for: $0) }
    )

    VStack(spacing: 0) {
      // Title + filter button
      HStack(alignment: .center) {
        Text("UTXOs")
          .font(.hbAmountLarge)
          .foregroundStyle(Color.hbTextPrimary)

        Spacer()

        filterButton
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 4)

      if visible.isEmpty, viewModel.outputs.isEmpty || (viewModel.utxos.isEmpty && !filter.isFiltering) {
        ContentUnavailableView(
          "No UTXOs",
          systemImage: "bitcoinsign.circle",
          description: Text("UTXOs will appear after refreshing your wallet")
        )
      } else if visible.isEmpty {
        ContentUnavailableView {
          Label("No Matching UTXOs", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("No outputs match the current filter")
        } actions: {
          Button("Reset Filters", action: resetShowFilters)
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      } else {
        List(visible) { utxo in
          NavigationLink(destination: UTXODetailView(utxo: utxo)) {
            utxoRow(utxo, isFrozen: frozen.contains(utxo.id), labels: labels)
          }
          .swipeActions(edge: .trailing) {
            if utxo.isSpent {
              EmptyView()
            } else if frozen.contains(utxo.id) {
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
    .sheet(isPresented: $showFilterSheet) {
      UTXOFilterSheet(filter: $filter)
        .navigationTransition(.zoom(sourceID: Self.filterTransitionID, in: filterNamespace))
    }
    .onAppear {
      viewModel.loadUTXOs()
    }
    .onChange(of: BitcoinService.shared.currentProfile?.id) {
      viewModel.loadUTXOs()
    }
  }

  // MARK: - Filter Button

  /// Sits in the title row rather than the toolbar, so the empty navigation bar
  /// stays collapsed like the other tabs. The sheet zooms out of it, as in Mail.
  private var filterButton: some View {
    Button {
      showFilterSheet = true
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(filter.isFiltering ? Color.hbBitcoinOrange : Color.hbTextPrimary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .matchedTransitionSource(id: Self.filterTransitionID, in: filterNamespace)
    .accessibilityLabel("Filter")
    .accessibilityValue(filter.isFiltering ? "On" : "Off")
    .accessibilityIdentifier("utxoFilterButton")
  }

  // MARK: - Row

  private func utxoRow(_ utxo: UTXOItem, isFrozen: Bool, labels: [String: String]) -> some View {
    let isSpent = utxo.isSpent
    let isDimmed = isSpent || isFrozen
    let spentInLabel = viewModel.spendingTxid(for: utxo).flatMap { labels["tx:\($0)"] }

    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Group {
          if isPrivate {
            Text(Constants.privacyText())
          } else if fiatEnabled, fiatPrimary, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(utxo.amount) {
            Text(fiatStr)
          } else {
            Text(utxo.amount.formattedSats)
          }
        }
        .font(.hbMono(14))
        .foregroundStyle(isDimmed ? Color.hbTextSecondary : Color.hbTextPrimary)

        Spacer()

        if isSpent {
          statusCapsule("Spent", color: Color.hbTextSecondary)
        } else {
          if isFrozen {
            statusCapsule("Frozen", color: Color.hbSteelBlue)
          }
          statusCapsule(
            utxo.isConfirmed ? "Confirmed" : "Unconfirmed",
            color: utxo.isConfirmed ? Color.hbSuccess : Color.hbBitcoinOrange
          )
        }
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

        if let label = labels["utxo:\(utxo.id)"], !label.isEmpty {
          HStack(spacing: 4) {
            Image(systemName: "tag.fill")
              .font(.system(size: 9))
            Text(String(label.prefix(60)))
              .font(.hbBody(11))
              .lineLimit(1)
          }
          .foregroundStyle(isSpent ? Color.hbTextSecondary : Color.hbSteelBlue)
        }
      }

      if let spentInLabel, !spentInLabel.isEmpty {
        HStack(spacing: 4) {
          Spacer()
          Image(systemName: "arrow.up.right")
            .font(.system(size: 9))
          Text("Spent in: \(String(spentInLabel.prefix(60)))")
            .font(.hbBody(11))
            .lineLimit(1)
        }
        .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .opacity(isSpent ? 0.45 : (isFrozen ? 0.6 : 1.0))
  }

  private func statusCapsule(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.hbLabel(10))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15))
      .clipShape(Capsule())
  }

  // MARK: - Lookups

  private var frozenOutpoints: Set<String> {
    guard let walletID else { return [] }
    return Set(frozenUTXOs.filter { $0.walletID == walletID }.map(\.outpoint))
  }

  /// This wallet's labels keyed "type:ref", e.g. "utxo:txid:vout" or "tx:txid"
  private var labelsByRef: [String: String] {
    guard let walletID else { return [:] }
    return Dictionary(
      walletLabels.filter { $0.walletID == walletID }.map { ("\($0.type):\($0.ref)", $0.label) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  // MARK: - Actions

  /// Turns the show toggles back to their defaults, keeping the chosen sort
  private func resetShowFilters() {
    var reset = UTXOFilter()
    reset.sort = filter.sort
    reset.ascending = filter.ascending
    filter = reset
  }

  private func freezeUTXO(_ utxo: UTXOItem) {
    guard let walletID else { return }
    modelContext.insert(FrozenUTXO(walletID: walletID, txid: utxo.txid, vout: utxo.vout))
    try? modelContext.save()
    AppLog(.utxo).info("Froze UTXO \(utxo.id) (\(utxo.amount) sats)")
  }

  private func unfreezeUTXO(_ utxo: UTXOItem) {
    guard let walletID else { return }
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

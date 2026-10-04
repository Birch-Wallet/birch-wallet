import SwiftData
import SwiftUI

private let logger = AppLog(.utxo)

struct UTXODetailView: View {
  let utxo: UTXOItem
  @Environment(\.modelContext) private var modelContext
  @Query private var frozenUTXOs: [FrozenUTXO]
  @Query private var walletLabels: [WalletLabel]
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @AppStorage(Constants.fiatPrimaryKey) private var fiatPrimary = false
  @State private var utxoLabel: String = ""
  @State private var isEditingLabel = false
  @State private var editedLabel: String = ""

  private var isPrivate: Bool {
    BitcoinService.shared.currentProfile?.privacyMode ?? false
  }

  private var service: BitcoinService {
    BitcoinService.shared
  }

  private var parentTransaction: TransactionItem? {
    service.transactions.first { $0.id == utxo.txid }
  }

  private var outputAddress: String? {
    guard let tx = parentTransaction,
          Int(utxo.vout) < tx.outputs.count else { return nil }
    return tx.outputs[Int(utxo.vout)].address
  }

  /// The wallet transaction that spent this output, when it is spent
  private var spendingTransaction: TransactionItem? {
    guard utxo.isSpent else { return nil }
    return service.transactions.first { tx in
      tx.inputs.contains { $0.prevTxid == utxo.txid && $0.prevVout == utxo.vout }
    }
  }

  private var isFrozen: Bool {
    guard !utxo.isSpent, let walletID = service.currentProfile?.id else { return false }
    return frozenUTXOs.contains { $0.walletID == walletID && $0.outpoint == utxo.id }
  }

  var body: some View {
    // Amounts format from the Bitcoin unit setting; read it so a change redraws them
    let _ = denomination
    ScrollView {
      VStack(spacing: 16) {
        // Amount header
        VStack(spacing: 8) {
          Image(systemName: isFrozen ? "snowflake" : (utxo.isSpent ? "bitcoinsign.circle" : "bitcoinsign.circle.fill"))
            .font(.system(size: 44))
            .foregroundStyle(isFrozen ? Color.hbSteelBlue : (utxo.isSpent ? Color.hbTextSecondary : Color.hbBitcoinOrange))

          if isPrivate {
            Text(Constants.privacyText())
              .font(.hbAmountMedium)
              .foregroundStyle(Color.hbTextPrimary)
          } else if fiatEnabled, fiatPrimary, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(utxo.amount) {
            Text(fiatStr)
              .font(.hbAmountMedium)
              .foregroundStyle(Color.hbTextPrimary)
            Text(utxo.amount.formattedSats)
              .font(.hbBody(14))
              .foregroundStyle(Color.hbTextSecondary)
          } else {
            Text(utxo.amount.formattedSats)
              .font(.hbAmountMedium)
              .foregroundStyle(Color.hbTextPrimary)
            if fiatEnabled, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(utxo.amount) {
              Text(fiatStr)
                .font(.hbBody(14))
                .foregroundStyle(Color.hbTextSecondary)
            }
          }

          HStack(spacing: 8) {
            if utxo.isSpent {
              Text("Spent")
                .font(.hbLabel(11))
                .foregroundStyle(Color.hbTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.hbTextSecondary.opacity(0.15))
                .clipShape(Capsule())
            } else if isFrozen {
              Text("Frozen")
                .font(.hbLabel(11))
                .foregroundStyle(Color.hbSteelBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.hbSteelBlue.opacity(0.15))
                .clipShape(Capsule())
            }

            if !utxo.isSpent {
              Text(utxo.isConfirmed ? "Confirmed" : "Unconfirmed")
                .font(.hbLabel(11))
                .foregroundStyle(utxo.isConfirmed ? Color.hbSuccess : Color.hbBitcoinOrange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((utxo.isConfirmed ? Color.hbSuccess : Color.hbBitcoinOrange).opacity(0.15))
                .clipShape(Capsule())
            }
          }
        }
        .onTapGesture(count: 2) {
          if fiatEnabled {
            fiatPrimary.toggle()
          }
        }
        .padding(.top, 8)

        // Output details
        VStack(spacing: 12) {
          if let address = outputAddress {
            VStack(alignment: .leading, spacing: 6) {
              Text("Address")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)

              HStack(alignment: .top, spacing: 8) {
                Group {
                  if isPrivate {
                    Text(Constants.privacyText(length: 8))
                      .font(.hbMono(12))
                      .foregroundStyle(Color.hbTextPrimary)
                  } else {
                    address.chunkedAddressText(font: .hbMono(12))
                      .textSelection(.enabled)
                  }
                }

                Spacer()

                if !isPrivate {
                  Button(action: {
                    UIPasteboard.general.string = address
                  }) {
                    Image(systemName: "doc.on.doc")
                      .font(.system(size: 14))
                      .foregroundStyle(Color.hbSteelBlue)
                  }

                  if let network = service.currentNetwork,
                     let url = network.explorerAddressURL(address: address, customHost: service.currentProfile?.blockExplorerHost)
                  {
                    Link(destination: url) {
                      Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.hbSteelBlue)
                    }
                  }
                }
              }

              if let addrLabel = addressLabel(for: address), !addrLabel.isEmpty {
                HStack(spacing: 4) {
                  Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                  Text(addrLabel)
                    .font(.hbBody(12))
                }
                .foregroundStyle(Color.hbSteelBlue)
              }
            }

            HBDivider()
          }

          DetailRow(label: "Amount", value: isPrivate ? Constants.privacyText() : utxo.amount.formattedSats)

          DetailRow(
            label: utxo.keychain == .external ? "Receive Address Index" : "Change Address Index",
            value: "\(utxo.derivationIndex)"
          )

          DetailRow(label: "Output Index", value: "\(utxo.vout)")

          DetailRow(label: "Type", value: utxo.keychain == .external ? "Receive" : "Change")

          if let tx = parentTransaction {
            if let blockHeight = tx.blockHeight {
              DetailRow(label: "Block Height", value: "\(blockHeight)")
            }

            if let timestamp = tx.timestamp {
              DetailRow(label: "Timestamp", value: timestamp.longFormatString)
            } else if let firstSeen = tx.firstSeen {
              DetailRow(label: "First Seen", value: firstSeen.longFormatString)
            }

            DetailRow(label: "Confirmations",
                      value: "\(tx.confirmations)")
          }
        }
        .hbCard()

        // Label
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Label")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            Spacer()
            if isEditingLabel {
              Button(action: saveUTXOLabel) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(Color.hbSuccess)
              }
            } else {
              Button(action: {
                editedLabel = utxoLabel
                isEditingLabel = true
              }) {
                Image(systemName: utxoLabel.isEmpty ? "plus.circle" : "pencil")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.hbSteelBlue)
              }
            }
          }
          if isEditingLabel {
            TextField("Add a label...", text: $editedLabel)
              .font(.hbBody())
              .labelLengthLimit($editedLabel)
              .padding(10)
              .birchCard(.nested)
              .foregroundStyle(Color.hbTextPrimary)
              .onSubmit { saveUTXOLabel() }
          } else if !utxoLabel.isEmpty {
            Text(utxoLabel)
              .font(.hbBody())
              .foregroundStyle(Color.hbTextPrimary)
          } else {
            Text("No label")
              .font(.hbBody())
              .foregroundStyle(Color.hbTextSecondary)
              .italic()
          }
        }
        .hbCard()

        // Outpoint
        VStack(alignment: .leading, spacing: 6) {
          Text("Outpoint")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)

          HStack(alignment: .top, spacing: 8) {
            Group {
              if isPrivate {
                Text(Constants.privacyText(length: 8))
                  .font(.hbMono(11))
                  .foregroundStyle(Color.hbTextPrimary)
              } else {
                Text(utxo.id)
                  .font(.hbMono(11))
                  .foregroundStyle(Color.hbTextPrimary)
                  .textSelection(.enabled)
              }
            }

            Spacer()

            if !isPrivate {
              Button(action: {
                UIPasteboard.general.string = utxo.id
              }) {
                Image(systemName: "doc.on.doc")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.hbSteelBlue)
              }

              if let network = service.currentNetwork,
                 let url = network.explorerTxURL(txid: utxo.txid, customHost: service.currentProfile?.blockExplorerHost)
              {
                Link(destination: url) {
                  Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.hbSteelBlue)
                }
              }
            }
          }
        }
        .hbCard()

        // Spending transaction
        if let spender = spendingTransaction {
          NavigationLink(destination: TransactionDetailView(transaction: spender, network: service.currentNetwork)) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Spent In")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)

              HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                  if let txLabel = txLabel(for: spender.id), !txLabel.isEmpty {
                    HStack(spacing: 4) {
                      Image(systemName: "tag.fill")
                        .font(.system(size: 10))
                      Text(txLabel)
                        .font(.hbBody(14))
                        .lineLimit(2)
                    }
                    .foregroundStyle(Color.hbSteelBlue)
                  }

                  Text(isPrivate ? Constants.privacyText(length: 8) : spender.id.truncatedMiddle(leading: 10, trailing: 8))
                    .font(.hbMono(12))
                    .foregroundStyle(Color.hbTextPrimary)

                  if let date = spender.timestamp ?? spender.firstSeen {
                    Text(date.longFormatString)
                      .font(.hbBody(12))
                      .foregroundStyle(Color.hbTextSecondary)
                  }
                }

                Spacer()

                Image(systemName: "chevron.right")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(Color.hbTextSecondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .hbCard()
        }

        // Freeze / Unfreeze action (spent outputs can't be frozen)
        if !utxo.isSpent {
          Button(action: toggleFreeze) {
            HStack(spacing: 8) {
              Image(systemName: isFrozen ? "flame" : "snowflake")
              Text(isFrozen ? "Unfreeze UTXO" : "Freeze UTXO")
                .font(.hbBody(15))
            }
            .foregroundStyle(isFrozen ? Color.hbBitcoinOrange : Color.hbSteelBlue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background((isFrozen ? Color.hbBitcoinOrange : Color.hbSteelBlue).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .hbCard()
        }
      }
      .padding(16)
    }
    .background(Color.hbBackground)
    .navigationTitle("UTXO Detail")
    .onAppear { loadUTXOLabel() }
  }

  private func loadUTXOLabel() {
    guard let walletID = service.currentProfile?.id else { return }
    let outpoint = utxo.id
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "utxo" && $0.ref == outpoint
    })
    utxoLabel = (try? modelContext.fetch(descriptor))?.first?.label ?? ""
  }

  private func saveUTXOLabel() {
    guard let walletID = service.currentProfile?.id else { return }
    let trimmed = editedLabel.trimmingCharacters(in: .whitespacesAndNewlines).truncatedLabel
    let outpoint = utxo.id
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "utxo" && $0.ref == outpoint
    })
    let existing = (try? modelContext.fetch(descriptor))?.first
    if trimmed.isEmpty {
      if let existing {
        modelContext.delete(existing)
      }
    } else if let existing {
      existing.label = trimmed
    } else {
      modelContext.insert(WalletLabel(walletID: walletID, type: .utxo, ref: outpoint, label: trimmed))
    }
    // Propagate to receive address if unlabeled
    if !trimmed.isEmpty, utxo.keychain == .external, let address = outputAddress {
      let addrType = "addr"
      let addrDescriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
        $0.walletID == walletID && $0.type == addrType && $0.ref == address
      })
      if (try? modelContext.fetch(addrDescriptor))?.first == nil {
        modelContext.insert(WalletLabel(walletID: walletID, type: .addr, ref: address, label: trimmed))
      }
    }
    do {
      try modelContext.save()
    } catch {
      logger.error("Failed to save UTXO label: \(error)")
    }
    utxoLabel = trimmed
    isEditingLabel = false
  }

  private func txLabel(for txid: String) -> String? {
    guard let walletID = service.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "tx" && $0.ref == txid })?.label
  }

  private func addressLabel(for address: String) -> String? {
    guard let walletID = service.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "addr" && $0.ref == address })?.label
  }

  private func toggleFreeze() {
    guard let walletID = service.currentProfile?.id else { return }
    if isFrozen {
      let txid = utxo.txid
      let descriptor = FetchDescriptor<FrozenUTXO>(predicate: #Predicate {
        $0.walletID == walletID && $0.txid == txid
      })
      let outpoint = utxo.id
      if let frozen = (try? modelContext.fetch(descriptor))?.first(where: { $0.outpoint == outpoint }) {
        modelContext.delete(frozen)
      }
    } else {
      modelContext.insert(FrozenUTXO(walletID: walletID, txid: utxo.txid, vout: utxo.vout))
    }
    do {
      try modelContext.save()
    } catch {
      logger.error("Failed to save UTXO freeze toggle: \(error)")
    }
  }
}

private struct DetailRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      Spacer()
      Text(value)
        .font(.hbMono())
        .foregroundStyle(Color.hbTextPrimary)
    }
  }
}

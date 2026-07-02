import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "birch", category: "TransactionDetailView")

struct TransactionDetailView: View {
  let transaction: TransactionItem
  var network: BitcoinNetwork?
  @Environment(\.modelContext) private var modelContext
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @AppStorage(Constants.fiatPrimaryKey) private var fiatPrimary = false
  @Query private var walletLabels: [WalletLabel]
  @State private var label: String = ""
  @State private var isEditingLabel = false
  @State private var editedLabel: String = ""
  @State private var showBumpFee = false

  private var isPrivate: Bool {
    BitcoinService.shared.currentProfile?.privacyMode ?? false
  }

  private var headerAmount: UInt64 {
    transaction.isSelfTransfer ? transaction.selfTransferAmount : transaction.absoluteAmount
  }

  private var directionText: String {
    if transaction.isSelfTransfer { return "Self Transfer" }
    return transaction.isIncoming ? "Received" : "Sent"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // Direction + Amount header
        VStack(spacing: 8) {
          Image(systemName: transaction.isSelfTransfer
            ? "arrow.triangle.2.circlepath.circle.fill"
            : (transaction.isIncoming ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill"))
            .font(.system(size: 44))
            .foregroundStyle(transaction.isIncoming && !transaction.isSelfTransfer ? Color.hbSuccess : Color.hbBitcoinOrange)

          if isPrivate {
            Text(Constants.privacyText())
              .font(.hbAmountMedium)
              .foregroundStyle(Color.hbTextPrimary)
          } else if fiatEnabled, fiatPrimary, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(headerAmount) {
            Text(fiatStr)
              .font(.hbAmountMedium)
              .foregroundStyle(Color.hbTextPrimary)
            Text(headerAmount.formattedSats)
              .font(.hbBody(14))
              .foregroundStyle(Color.hbTextSecondary)
          } else {
            Text(headerAmount.formattedSats)
              .font(.hbAmountMedium)
              .foregroundStyle(Color.hbTextPrimary)
            if fiatEnabled, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(headerAmount) {
              Text(fiatStr)
                .font(.hbBody(14))
                .foregroundStyle(Color.hbTextSecondary)
            }
          }

          Text(directionText)
            .font(.hbBody())
            .foregroundStyle(Color.hbTextSecondary)
        }
        .onTapGesture(count: 2) {
          if fiatEnabled { fiatPrimary.toggle() }
        }
        .padding(.top, 8)

        // Label
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Label")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            Spacer()
            if isEditingLabel {
              Button(action: saveLabel) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(Color.hbSuccess)
              }
            } else {
              Button(action: {
                editedLabel = label
                isEditingLabel = true
              }) {
                Image(systemName: label.isEmpty ? "plus.circle" : "pencil")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.hbSteelBlue)
              }
            }
          }
          if isEditingLabel {
            TextField("Add a label...", text: $editedLabel)
              .font(.hbBody())
              .padding(10)
              .background(Color.hbSurfaceElevated)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .foregroundStyle(Color.hbTextPrimary)
              .onSubmit { saveLabel() }
          } else if !label.isEmpty {
            Text(label)
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

        // Transaction ID
        VStack(alignment: .leading, spacing: 6) {
          Text("Transaction ID")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)

          HStack(alignment: .top, spacing: 8) {
            Group {
              if isPrivate {
                Text(Constants.privacyText(length: 8))
                  .font(.hbMono(11))
                  .foregroundStyle(Color.hbTextPrimary)
              } else {
                Text(transaction.id)
                  .font(.hbMono(11))
                  .foregroundStyle(Color.hbTextPrimary)
                  .textSelection(.enabled)
              }
            }

            Spacer()

            if !isPrivate {
              Button(action: {
                UIPasteboard.general.string = transaction.id
              }) {
                Image(systemName: "doc.on.doc")
                  .font(.system(size: 14))
                  .foregroundStyle(Color.hbSteelBlue)
              }

              if let network, let url = network.explorerTxURL(txid: transaction.id, customHost: BitcoinService.shared.currentProfile?.blockExplorerHost) {
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

        // Status details
        VStack(spacing: 12) {
          DetailRow(label: "Status") {
            HStack(spacing: 6) {
              if transaction.isConfirmed {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(Color.hbSuccess)
                Text("Confirmed")
                  .font(.hbBody())
                  .foregroundStyle(Color.hbSuccess)
              } else {
                Image(systemName: "clock")
                  .foregroundStyle(Color.hbBitcoinOrange)
                Text("Unconfirmed")
                  .font(.hbBody())
                  .foregroundStyle(Color.hbBitcoinOrange)
              }
            }
          }

          if transaction.confirmations > 0 {
            DetailRow(label: "Confirmations") {
              Text(transaction.confirmations >= 6 ? "6+" : "\(transaction.confirmations)")
                .font(.hbMono())
                .foregroundStyle(Color.hbTextPrimary)
            }
          }

          if let blockHeight = transaction.blockHeight {
            DetailRow(label: "Block Height") {
              Text("\(blockHeight)")
                .font(.hbMono())
                .foregroundStyle(Color.hbTextPrimary)
            }
          }

          if let timestamp = transaction.timestamp {
            DetailRow(label: "Timestamp") {
              Text(timestamp.longFormatString)
                .font(.hbBody())
                .foregroundStyle(Color.hbTextPrimary)
            }
          } else if let firstSeen = transaction.firstSeen {
            DetailRow(label: "First Seen") {
              Text(firstSeen.longFormatString)
                .font(.hbBody())
                .foregroundStyle(Color.hbTextPrimary)
            }
          }

          if let fee = transaction.fee {
            DetailRow(label: "Fee") {
              Text(isPrivate ? Constants.privacyText() : fee.formattedSats)
                .font(.hbMono())
                .foregroundStyle(Color.hbTextPrimary)
            }

            if let rate = transaction.currentFeeRate {
              DetailRow(label: "Fee Rate") {
                Text(isPrivate ? Constants.privacyText() : String(format: rate == rate.rounded() ? "%.0f sat/vB" : "%.2f sat/vB", rate))
                  .font(.hbMono())
                  .foregroundStyle(Color.hbTextPrimary)
              }
            }
          }
        }
        .hbCard()

        // Flow diagram
        if !transaction.inputs.isEmpty || !transaction.outputs.isEmpty {
          TransactionDetailFlowDiagram(transaction: transaction, isPrivate: isPrivate)
            .hbCard()
        }

        // Inputs
        if !transaction.inputs.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Inputs (\(transaction.inputs.count))")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)

            ForEach(transaction.inputs) { input in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(isPrivate ? Constants.privacyText(length: 8) : input.address)
                    .font(.hbMono(11))
                    .foregroundStyle(Color.hbTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer()
                if input.amount > 0 {
                  Text(isPrivate ? Constants.privacyText() : input.amount.formattedSats)
                    .font(.hbMono(12))
                    .foregroundStyle(Color.hbTextPrimary)
                }
              }
              .padding(.vertical, 4)

              if input.id != transaction.inputs.last?.id {
                Divider().overlay(Color.hbBorder)
              }
            }
          }
          .hbCard()
        }

        // Outputs
        if !transaction.outputs.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Outputs (\(transaction.outputs.count))")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)

            ForEach(Array(transaction.outputs.enumerated()), id: \.element.id) { vout, output in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    if isPrivate {
                      Text(Constants.privacyText(length: 8))
                        .font(.hbMono(11))
                        .foregroundStyle(Color.hbTextPrimary)
                        .lineLimit(1)
                    } else {
                      Text(output.address)
                        .font(.hbMono(11))
                        .foregroundStyle(Color.hbTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    }
                  }
                  Spacer()
                  Text(isPrivate ? Constants.privacyText() : output.amount.formattedSats)
                    .font(.hbMono(12))
                    .foregroundStyle(Color.hbTextPrimary)
                }

                let outputDisplayLabel: String? = utxoLabel(vout: vout) ?? (output.isMine ? addressLabel(for: output.address) : nil)
                if let displayLabel = outputDisplayLabel, !displayLabel.isEmpty {
                  HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                      .font(.system(size: 10))
                    Text(displayLabel)
                      .font(.hbBody(12))
                  }
                  .foregroundStyle(Color.hbSteelBlue)
                }
              }
              .padding(.vertical, 4)

              if output.id != transaction.outputs.last?.id {
                Divider().overlay(Color.hbBorder)
              }
            }
          }
          .hbCard()
        }

        // Bump Fee button for eligible transactions
        if transaction.isRbfEligible {
          Button(action: { showBumpFee = true }) {
            Label("Bump Fee", systemImage: "arrow.up.circle")
              .font(.hbBody(16))
              .foregroundStyle(Color.hbBitcoinOrange)
              .frame(maxWidth: .infinity)
              .padding(14)
              .background(Color.hbBitcoinOrange.opacity(0.1))
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
      }
      .padding(16)
    }
    .background(Color.hbBackground)
    .navigationTitle("Transaction")
    .sheet(isPresented: $showBumpFee) {
      BumpFeeView(viewModel: BumpFeeViewModel(transaction: transaction))
    }
    .onAppear {
      loadLabel()
    }
  }

  private func addressLabel(for address: String) -> String? {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "addr" && $0.ref == address })?.label
  }

  private func utxoLabel(vout: Int) -> String? {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return nil }
    let outpoint = "\(transaction.id):\(vout)"
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "utxo" && $0.ref == outpoint })?.label
  }

  private func loadLabel() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    let txid = transaction.id
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "tx" && $0.ref == txid
    })
    label = (try? modelContext.fetch(descriptor))?.first?.label ?? ""
  }

  private func saveLabel() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    var trimmed = editedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.utf8.count > WalletLabel.maxLabelLength {
      trimmed = String(trimmed.utf8.prefix(WalletLabel.maxLabelLength))!
    }
    let txid = transaction.id
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "tx" && $0.ref == txid
    })
    let existing = (try? modelContext.fetch(descriptor))?.first

    if trimmed.isEmpty {
      if let existing { modelContext.delete(existing) }
    } else if let existing {
      existing.label = trimmed
    } else {
      modelContext.insert(WalletLabel(walletID: walletID, type: .tx, ref: transaction.id, label: trimmed))
    }
    try? modelContext.save()
    label = trimmed
    isEditingLabel = false

    // Propagate to related UTXOs and receive address if this is an incoming tx
    if !trimmed.isEmpty {
      do {
        try LabelService.propagateFromTxLabel(
          txid: transaction.id,
          newLabel: trimmed,
          transaction: transaction,
          utxos: BitcoinService.shared.utxos,
          context: modelContext,
          walletID: walletID
        )
      } catch {
        logger.error("Failed to propagate tx label: \(error.localizedDescription)")
      }
    }
  }
}

// MARK: - Transaction Detail Flow Diagram

private struct TransactionDetailFlowDiagram: View {
  let transaction: TransactionItem
  var isPrivate: Bool = false

  private struct FlowEntry: Identifiable {
    let id = UUID()
    let label: String
    let isMine: Bool
    let isPlaceholder: Bool

    var color: Color {
      if isPlaceholder { return .hbTextSecondary }
      return isMine ? .hbSteelBlue : .hbTextPrimary
    }
  }

  private var inputEntries: [FlowEntry] {
    transaction.inputs.map { FlowEntry(label: isPrivate ? Constants.privacyText(length: 4) : shortAddress($0.address), isMine: $0.isMine, isPlaceholder: false) }
  }

  private var walletAddressMaps: (change: [String: UInt32], receive: [String: UInt32]) {
    let changeAddresses = BitcoinService.shared.getAddresses(keychain: .internal)
    let receiveAddresses = BitcoinService.shared.getAddresses(keychain: .external)
    return (
      change: Dictionary(uniqueKeysWithValues: changeAddresses.map { ($0.address, $0.index) }),
      receive: Dictionary(uniqueKeysWithValues: receiveAddresses.map { ($0.address, $0.index) })
    )
  }

  private var outputEntries: [FlowEntry] {
    let maps = walletAddressMaps
    var entries: [FlowEntry] = transaction.outputs.map { output in
      if output.isMine, let index = maps.change[output.address] {
        return FlowEntry(label: "Change #\(index)", isMine: true, isPlaceholder: false)
      }
      if output.isMine, let index = maps.receive[output.address] {
        return FlowEntry(label: "Receive #\(index)", isMine: true, isPlaceholder: false)
      }
      return FlowEntry(label: isPrivate ? Constants.privacyText(length: 4) : shortAddress(output.address), isMine: output.isMine, isPlaceholder: false)
    }
    if let fee = transaction.fee, fee > 0 {
      let feeMine = !transaction.isIncoming
      entries.append(FlowEntry(label: "fee", isMine: feeMine, isPlaceholder: false))
    }
    return entries
  }

  private var hasAnyMine: Bool {
    transaction.inputs.contains(where: \.isMine) ||
      transaction.outputs.contains(where: \.isMine) ||
      !transaction.isIncoming
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Transaction Flow")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      GeometryReader { geo in
        let w = geo.size.width
        let inputs = inputEntries
        let outputs = outputEntries
        let leftCount = CGFloat(inputs.count)
        let rightCount = CGFloat(outputs.count)
        let maxCount = max(leftCount, rightCount)
        let rowH: CGFloat = 28
        let totalH = maxCount * rowH
        let centerX = w / 2

        Canvas { context, _ in
          let mergeY = totalH / 2

          for i in 0 ..< inputs.count {
            let y = flowY(index: i, count: inputs.count, totalH: totalH, rowH: rowH)
            let lineColor = inputs[i].isMine ? Color.hbSteelBlue : Color.hbBitcoinOrange
            var path = Path()
            path.move(to: CGPoint(x: centerX * 0.45, y: y))
            path.addCurve(
              to: CGPoint(x: centerX, y: mergeY),
              control1: CGPoint(x: centerX * 0.75, y: y),
              control2: CGPoint(x: centerX * 0.85, y: mergeY)
            )
            context.stroke(path, with: .color(lineColor.opacity(0.35)), lineWidth: 1.5)
          }

          for i in 0 ..< outputs.count {
            let y = flowY(index: i, count: outputs.count, totalH: totalH, rowH: rowH)
            let lineColor = outputs[i].isMine ? Color.hbSteelBlue : Color.hbBitcoinOrange
            var path = Path()
            path.move(to: CGPoint(x: centerX, y: mergeY))
            path.addCurve(
              to: CGPoint(x: w - centerX * 0.45, y: y),
              control1: CGPoint(x: centerX * 1.15, y: mergeY),
              control2: CGPoint(x: centerX * 1.25, y: y)
            )
            context.stroke(path, with: .color(lineColor.opacity(0.35)), lineWidth: 1.5)
          }
        }
        .frame(height: totalH)

        // Input labels
        ForEach(Array(inputs.enumerated()), id: \.element.id) { i, entry in
          let y = flowY(index: i, count: inputs.count, totalH: totalH, rowH: rowH)
          Text(entry.label)
            .font(.hbMono(10))
            .foregroundStyle(entry.color)
            .position(x: centerX * 0.2, y: y)
        }

        // Output labels
        ForEach(Array(outputs.enumerated()), id: \.element.id) { i, entry in
          let y = flowY(index: i, count: outputs.count, totalH: totalH, rowH: rowH)
          Text(entry.label)
            .font(.hbMono(10))
            .foregroundStyle(entry.color)
            .position(x: w - centerX * 0.2, y: y)
        }
      }
      .frame(height: CGFloat(max(inputEntries.count, outputEntries.count)) * 28)

      // Legend
      if hasAnyMine {
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.hbSteelBlue)
            .frame(width: 10, height: 10)
          Text("My Wallet")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .padding(.top, 4)
      }
    }
  }

  private func flowY(index: Int, count: Int, totalH: CGFloat, rowH: CGFloat) -> CGFloat {
    guard count > 1 else { return totalH / 2 }
    let spacing = min(rowH, totalH / CGFloat(count))
    let blockH = spacing * CGFloat(count - 1)
    let startY = (totalH - blockH) / 2
    return startY + CGFloat(index) * spacing
  }

  private func shortAddress(_ address: String) -> String {
    guard address.count > 12 else { return address }
    return "\(address.prefix(6))…\(address.suffix(4))"
  }
}

private struct DetailRow<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  var body: some View {
    HStack {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      Spacer()
      content
    }
  }
}

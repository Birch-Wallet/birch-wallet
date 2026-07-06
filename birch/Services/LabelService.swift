import Foundation
import SwiftData

private let logger = AppLog(.labels)

/// Handles label propagation between transactions, UTXOs, and addresses.
enum LabelService {
  /// Called after sync: for each incoming transaction whose receive address has a label,
  /// copy that label to the transaction (if unlabeled) and to its UTXOs (if unlabeled).
  static func propagateAddressLabels(
    transactions: [TransactionItem],
    utxos: [UTXOItem],
    context: ModelContext,
    walletID: UUID
  ) throws {
    let allLabels = fetchAllLabels(walletID: walletID, context: context)
    let addrLabels = Dictionary(
      allLabels.filter { $0.type == "addr" }.map { ($0.ref, $0.label) },
      uniquingKeysWith: { first, _ in first }
    )
    let txLabelRefs = Set(allLabels.filter { $0.type == "tx" }.map(\.ref))
    let utxoLabelRefs = Set(allLabels.filter { $0.type == "utxo" }.map(\.ref))

    var didChange = false

    for tx in transactions where tx.isIncoming {
      // Find first output address that carries a label
      guard let addrLabel = tx.outputs
        .compactMap({ addrLabels[$0.address] })
        .first(where: { !$0.isEmpty })
      else { continue }

      // Propagate to tx if it has no label yet
      if !txLabelRefs.contains(tx.id) {
        context.insert(WalletLabel(walletID: walletID, type: .tx, ref: tx.id, label: addrLabel))
        didChange = true
      }

      // Propagate to each UTXO from this tx that has no label yet
      for utxo in utxos where utxo.txid == tx.id {
        if !utxoLabelRefs.contains(utxo.id) {
          context.insert(WalletLabel(walletID: walletID, type: .utxo, ref: utxo.id, label: addrLabel))
          didChange = true
        }
      }
    }

    if didChange {
      do {
        try context.save()
      } catch {
        logger.error("Failed to save propagated address labels: \(error)")
        throw error
      }
    }
  }

  /// Called after saving a receive transaction's label.
  /// - Copies the label to related UTXOs that have no label yet.
  /// - Copies the label to receive addresses from that tx that have no label yet.
  static func propagateFromTxLabel(
    txid: String,
    newLabel: String,
    transaction: TransactionItem,
    utxos: [UTXOItem],
    context: ModelContext,
    walletID: UUID
  ) throws {
    guard transaction.isIncoming, !newLabel.isEmpty else { return }

    let allLabels = fetchAllLabels(walletID: walletID, context: context)
    let utxoLabelRefs = Set(allLabels.filter { $0.type == "utxo" }.map(\.ref))
    let addrLabelRefs = Set(allLabels.filter { $0.type == "addr" }.map(\.ref))

    var didChange = false

    for utxo in utxos where utxo.txid == txid {
      if !utxoLabelRefs.contains(utxo.id) {
        context.insert(WalletLabel(walletID: walletID, type: .utxo, ref: utxo.id, label: newLabel))
        didChange = true
      }
    }

    for output in transaction.outputs where output.isMine {
      if !addrLabelRefs.contains(output.address) {
        context.insert(WalletLabel(walletID: walletID, type: .addr, ref: output.address, label: newLabel))
        didChange = true
      }
    }

    if didChange {
      do {
        try context.save()
      } catch {
        logger.error("Failed to save propagated tx labels: \(error)")
        throw error
      }
    }
  }

  /// Called after a send transaction is broadcast.
  /// Labels the change address and change UTXO as "Change From: <txLabel>".
  static func propagateChangeLabel(
    txid: String,
    txLabel: String,
    changeAddress: String,
    changeVout: UInt32,
    context: ModelContext,
    walletID: UUID
  ) throws {
    guard !txLabel.isEmpty, !changeAddress.isEmpty else { return }
    let changeLabel = "Change From: \(txLabel)"
    let allLabels = fetchAllLabels(walletID: walletID, context: context)
    let addrLabelRefs = Set(allLabels.filter { $0.type == "addr" }.map(\.ref))
    let utxoLabelRefs = Set(allLabels.filter { $0.type == "utxo" }.map(\.ref))

    var didChange = false

    if !addrLabelRefs.contains(changeAddress) {
      context.insert(WalletLabel(walletID: walletID, type: .addr, ref: changeAddress, label: changeLabel))
      didChange = true
    }

    let utxoRef = "\(txid):\(changeVout)"
    if !utxoLabelRefs.contains(utxoRef) {
      context.insert(WalletLabel(walletID: walletID, type: .utxo, ref: utxoRef, label: changeLabel))
      didChange = true
    }

    if didChange {
      do {
        try context.save()
      } catch {
        logger.error("Failed to save propagated change labels: \(error)")
        throw error
      }
    }
  }

  // MARK: - BIP 329 Import

  /// Imports labels from BIP 329 JSONL data. Only updates/creates labels where the import has a non-empty label.
  /// Existing labels in the wallet are preserved if the import record has no label.
  /// Returns the number of labels imported/updated.
  @discardableResult
  static func importBIP329(
    data: Data,
    walletID: UUID,
    cosigners: [CosignerInfo],
    context: ModelContext
  ) throws -> Int {
    let records = BIP329Record.parseFromJSONL(data)
    let existingLabels = fetchAllLabels(walletID: walletID, context: context)

    // Build lookup: "type:ref" → WalletLabel for existing labels
    let existingByKey = Dictionary(
      existingLabels.map { ("\($0.type):\($0.ref)", $0) },
      uniquingKeysWith: { first, _ in first }
    )

    // Fetch existing frozen UTXOs for this wallet
    let frozenDescriptor = FetchDescriptor<FrozenUTXO>(predicate: #Predicate { $0.walletID == walletID })
    let existingFrozen = (try? context.fetch(frozenDescriptor)) ?? []
    let frozenByOutpoint = Dictionary(
      existingFrozen.map { ($0.outpoint, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var importedCount = 0

    for record in records {
      let label = record.label
      let hasLabel = label != nil && !label!.isEmpty

      switch record.type {
      case "tx":
        if hasLabel {
          importedCount += upsertLabel(
            key: "tx:\(record.ref)", type: .tx, ref: record.ref,
            label: label!, walletID: walletID, existing: existingByKey, context: context
          )
        }

      case "addr":
        if hasLabel {
          importedCount += upsertLabel(
            key: "addr:\(record.ref)", type: .addr, ref: record.ref,
            label: label!, walletID: walletID, existing: existingByKey, context: context
          )
        }

      case "output":
        // BIP 329 "output" maps to internal "utxo"
        if hasLabel {
          importedCount += upsertLabel(
            key: "utxo:\(record.ref)", type: .utxo, ref: record.ref,
            label: label!, walletID: walletID, existing: existingByKey, context: context
          )
        }

        // Sync frozen/unfrozen state from spendable field
        if let spendable = record.spendable {
          let outpoint = record.ref
          if spendable, let frozen = frozenByOutpoint[outpoint] {
            // Import says spendable but we have it frozen — unfreeze
            context.delete(frozen)
            importedCount += 1
          } else if !spendable, frozenByOutpoint[outpoint] == nil {
            // Import says not spendable but we don't have it frozen — freeze
            let parts = outpoint.split(separator: ":")
            if parts.count == 2, let vout = UInt32(parts[1]) {
              context.insert(FrozenUTXO(walletID: walletID, txid: String(parts[0]), vout: vout))
              importedCount += 1
            }
          }
        }

      case "xpub":
        // Update cosigner label if matching xpub found
        if hasLabel {
          if let cosigner = cosigners.first(where: { $0.xpub == record.ref }) {
            if cosigner.label != label! {
              cosigner.label = label!
              importedCount += 1
            }
          }
        }

      default:
        break
      }
    }

    if importedCount > 0 {
      do {
        try context.save()
      } catch {
        logger.error("Failed to save BIP329 import (\(importedCount) labels): \(error)")
        throw error
      }
    }
    return importedCount
  }

  /// Inserts or updates a label. Returns 1 if a change was made, 0 otherwise.
  private static func upsertLabel(
    key: String,
    type: WalletLabel.LabelType,
    ref: String,
    label: String,
    walletID: UUID,
    existing: [String: WalletLabel],
    context: ModelContext
  ) -> Int {
    if let existingLabel = existing[key] {
      if existingLabel.label != label {
        existingLabel.label = label
        return 1
      }
      return 0
    } else {
      context.insert(WalletLabel(walletID: walletID, type: type, ref: ref, label: label))
      return 1
    }
  }

  // MARK: - BIP 329 Export

  /// Exports all wallet data as BIP 329 JSONL. Fetches labels from SwiftData, then delegates to the pure method.
  static func exportBIP329(
    walletID: UUID,
    context: ModelContext,
    transactions: [TransactionItem],
    utxos: [UTXOItem],
    frozenOutpoints: Set<String>,
    receiveAddresses: [AddressItem],
    changeAddresses: [AddressItem],
    cosigners: [CosignerInfo],
    requiredSignatures: Int,
    network: BitcoinNetwork
  ) -> Data {
    let labels = fetchAllLabels(walletID: walletID, context: context)
    let records = buildBIP329Records(
      labels: labels,
      transactions: transactions,
      utxos: utxos,
      frozenOutpoints: frozenOutpoints,
      receiveAddresses: receiveAddresses,
      changeAddresses: changeAddresses,
      cosigners: cosigners,
      requiredSignatures: requiredSignatures,
      network: network
    )
    return BIP329Record.encodeToJSONL(records)
  }

  /// Pure/testable method — builds BIP 329 records from pre-fetched data.
  static func buildBIP329Records(
    labels: [WalletLabel],
    transactions: [TransactionItem],
    utxos: [UTXOItem],
    frozenOutpoints: Set<String>,
    receiveAddresses: [AddressItem],
    changeAddresses: [AddressItem],
    cosigners: [CosignerInfo],
    requiredSignatures: Int,
    network _: BitcoinNetwork
  ) -> [BIP329Record] {
    // Build lookup dictionaries
    let labelsByTypeAndRef = Dictionary(
      labels.map { ("\($0.type):\($0.ref)", $0.label) },
      uniquingKeysWith: { first, _ in first }
    )
    let utxoOutpoints = Set(utxos.map(\.id))
    let origin = buildOrigin(cosigners: cosigners, requiredSignatures: requiredSignatures)
    let addressKeypaths = buildAddressKeypaths(receiveAddresses: receiveAddresses, changeAddresses: changeAddresses)
    let addressHeights = buildAddressHeights(transactions: transactions, addressKeypaths: addressKeypaths)

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    var records: [BIP329Record] = []

    // 1. xpub records
    for cosigner in cosigners.sorted(by: { $0.xpub < $1.xpub }) {
      records.append(BIP329Record(
        type: "xpub",
        ref: cosigner.xpub,
        label: cosigner.label
      ))
    }

    // 2. tx records
    for tx in transactions {
      let hasEnoughConfs = tx.confirmations >= 6
      var record = BIP329Record(type: "tx", ref: tx.id)
      record.label = labelsByTypeAndRef["tx:\(tx.id)"]
      record.origin = origin
      if hasEnoughConfs, let h = tx.blockHeight {
        record.height = h
        if let ts = tx.timestamp {
          record.time = isoFormatter.string(from: ts)
        }
      }
      record.fee = tx.fee
      record.value = tx.amount
      records.append(record)
    }

    // 3. addr records
    let allAddresses = receiveAddresses + changeAddresses
    for addr in allAddresses {
      var record = BIP329Record(type: "addr", ref: addr.address)
      record.label = labelsByTypeAndRef["addr:\(addr.address)"]
      record.origin = origin
      record.keypath = addressKeypaths[addr.address]
      record.heights = addressHeights[addr.address] ?? []
      records.append(record)
    }

    // 4. output records
    for tx in transactions {
      let hasEnoughConfs = tx.confirmations >= 6
      for (outputIndex, output) in tx.outputs.enumerated() where output.isMine {
        let outpoint = "\(tx.id):\(outputIndex)"
        var record = BIP329Record(type: "output", ref: outpoint)
        record.origin = origin
        record.keypath = addressKeypaths[output.address]
        record.value = Int64(output.amount)
        if hasEnoughConfs, let h = tx.blockHeight {
          record.height = h
          if let ts = tx.timestamp {
            record.time = isoFormatter.string(from: ts)
          }
        }
        record.label = labelsByTypeAndRef["utxo:\(outpoint)"]
        // spendable only on unspent outputs (current UTXOs)
        if utxoOutpoints.contains(outpoint) {
          record.spendable = !frozenOutpoints.contains(outpoint)
        }
        records.append(record)
      }
    }

    // 5. input records
    for tx in transactions {
      let hasEnoughConfs = tx.confirmations >= 6
      for (inputIndex, input) in tx.inputs.enumerated() where input.isMine {
        let ref = "\(tx.id):\(inputIndex)"
        var record = BIP329Record(type: "input", ref: ref)
        record.origin = origin
        record.keypath = addressKeypaths[input.address]
        record.value = Int64(input.amount)
        if hasEnoughConfs, let h = tx.blockHeight {
          record.height = h
          if let ts = tx.timestamp {
            record.time = isoFormatter.string(from: ts)
          }
        }
        if let prevTxid = input.prevTxid, let prevVout = input.prevVout {
          record.label = labelsByTypeAndRef["utxo:\(prevTxid):\(prevVout)"]
        }
        records.append(record)
      }
    }

    return records
  }

  // MARK: - BIP 329 Helpers

  /// Builds abbreviated origin descriptor: `wsh(sortedmulti(M,[fp/path],[fp/path]))`
  private static func buildOrigin(cosigners: [CosignerInfo], requiredSignatures: Int) -> String {
    let sorted = cosigners.sorted { $0.xpub < $1.xpub }
    let keys = sorted.map { cosigner in
      let path = cosigner.derivationPath
        .replacingOccurrences(of: "m/", with: "")
        .replacingOccurrences(of: "'", with: "h")
      return "[\(cosigner.fingerprint)/\(path)]"
    }
    return "wsh(sortedmulti(\(requiredSignatures),\(keys.joined(separator: ","))))"
  }

  /// Builds address → keypath dictionary from receive and change addresses.
  private static func buildAddressKeypaths(
    receiveAddresses: [AddressItem],
    changeAddresses: [AddressItem]
  ) -> [String: String] {
    var result: [String: String] = [:]
    for addr in receiveAddresses {
      result[addr.address] = "/0/\(addr.index)"
    }
    for addr in changeAddresses {
      result[addr.address] = "/1/\(addr.index)"
    }
    return result
  }

  /// Scans confirmed transactions to find which block heights each address appeared in.
  private static func buildAddressHeights(
    transactions: [TransactionItem],
    addressKeypaths: [String: String]
  ) -> [String: [UInt32]] {
    var heightSets: [String: Set<UInt32>] = [:]
    for tx in transactions {
      guard tx.confirmations >= 6, let h = tx.blockHeight else { continue }
      let allIOs = tx.inputs.filter(\.isMine) + tx.outputs.filter(\.isMine)
      for io in allIOs where addressKeypaths[io.address] != nil {
        heightSets[io.address, default: []].insert(h)
      }
    }
    return heightSets.mapValues { $0.sorted() }
  }

  // MARK: - Private

  private static func fetchAllLabels(walletID: UUID, context: ModelContext) -> [WalletLabel] {
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate { $0.walletID == walletID })
    do {
      return try context.fetch(descriptor)
    } catch {
      logger.error("Failed to fetch labels for wallet \(walletID): \(error)")
      return []
    }
  }
}

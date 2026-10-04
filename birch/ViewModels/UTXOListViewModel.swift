import Foundation
import Observation

@Observable
@MainActor
final class UTXOListViewModel {
  var utxos: [UTXOItem] = []
  /// Every output, spent and unspent — the list filters these
  var outputs: [UTXOItem] = []
  /// Outpoint ("txid:vout") → txid of the transaction that spent it
  private var spentBy: [String: String] = [:]
  /// Wallet transactions keyed by txid, rebuilt alongside the outputs
  private var txByID: [String: TransactionItem] = [:]

  var totalAmount: UInt64 {
    utxos.reduce(0) { $0 + $1.amount }
  }

  private var bitcoinService: BitcoinService {
    BitcoinService.shared
  }

  func loadUTXOs() {
    let transactions = bitcoinService.transactions
    utxos = bitcoinService.utxos
    outputs = bitcoinService.outputs
    txByID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    spentBy = Self.spendingTxids(in: transactions)
  }

  func address(for utxo: UTXOItem) -> String? {
    guard let tx = txByID[utxo.txid], Int(utxo.vout) < tx.outputs.count else { return nil }
    return tx.outputs[Int(utxo.vout)].address
  }

  func bestDate(for utxo: UTXOItem) -> Date? {
    guard let tx = txByID[utxo.txid] else { return nil }
    return tx.timestamp ?? tx.firstSeen
  }

  func spendingTxid(for utxo: UTXOItem) -> String? {
    guard utxo.isSpent else { return nil }
    return spentBy[utxo.id]
  }

  func spendingTransaction(for utxo: UTXOItem) -> TransactionItem? {
    spendingTxid(for: utxo).flatMap { txByID[$0] }
  }

  /// Maps each outpoint spent by one of these transactions to the spender's txid
  nonisolated static func spendingTxids(in transactions: [TransactionItem]) -> [String: String] {
    var map: [String: String] = [:]
    for tx in transactions {
      for input in tx.inputs {
        guard let prevTxid = input.prevTxid, let prevVout = input.prevVout else { continue }
        map["\(prevTxid):\(prevVout)"] = tx.id
      }
    }
    return map
  }
}

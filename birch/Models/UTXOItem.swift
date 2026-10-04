import Foundation

struct UTXOItem: Identifiable, Equatable {
  let txid: String
  let vout: UInt32
  let amount: UInt64 // sats
  let isConfirmed: Bool
  let keychain: KeychainKind
  let derivationIndex: UInt32
  /// Spent by a transaction this wallet knows about. Only the UTXO list's spent
  /// filter shows these; `BitcoinService.utxos` never contains spent outputs.
  var isSpent = false

  var id: String {
    "\(txid):\(vout)"
  }

  enum KeychainKind: String {
    case external
    case `internal`
  }
}

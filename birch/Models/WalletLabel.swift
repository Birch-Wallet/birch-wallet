import Foundation
import SwiftData

@Model
final class WalletLabel {
  var id: UUID
  var walletID: UUID
  var type: String // "tx" or "addr"
  var ref: String // txid or address string
  var label: String
  var createdAt: Date

  init(walletID: UUID, type: LabelType, ref: String, label: String) {
    id = UUID()
    self.walletID = walletID
    self.type = type.rawValue
    self.ref = ref
    self.label = label
    createdAt = Date()
  }

  enum LabelType: String {
    case tx
    case addr
    case utxo
  }

  /// Maximum label length in characters (what the user sees, so an emoji
  /// counts as one). Enforced while typing and on save/import via `truncatedLabel`.
  static let maxLabelLength = 255

  var labelType: LabelType {
    LabelType(rawValue: type) ?? .tx
  }
}

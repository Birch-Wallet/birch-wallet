import Foundation
import SwiftData

@Model
final class SavedPSBT {
  var id: UUID
  var walletID: UUID
  var name: String
  var psbtBytes: Data
  var psbtBase64: String
  var signaturesCollected: Int
  var requiredSignatures: Int
  var createdAt: Date
  var updatedAt: Date
  var recipientsJSON: Data
  var feeRateSatVb: String
  var totalFee: UInt64
  var changeAmount: UInt64?
  var changeAddress: String?
  var inputCount: Int
  var manualUTXOSelection: Bool
  var selectedUTXOIds: String
  var inputOutpoints: String // Comma-separated "txid:vout" of PSBT inputs
  var originalTxid: String? // Non-nil for RBF (bump fee) PSBTs — the txid being replaced

  static let maxNameLength = 100

  /// How long after its last save a PSBT is still offered when Send opens. Older ones
  /// are only reachable from the Saved PSBTs list.
  static let resumePromptWindow: TimeInterval = 48 * 60 * 60

  /// The PSBT to offer on opening Send: the wallet's most recently saved one, and only
  /// if it was saved within `resumePromptWindow`. Never falls back to an older PSBT.
  static func resumeCandidate(in saved: [SavedPSBT], walletID: UUID, now: Date = .now) -> SavedPSBT? {
    guard let latest = saved
      .filter({ $0.walletID == walletID })
      .max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
    return now.timeIntervalSince(latest.updatedAt) < resumePromptWindow ? latest : nil
  }

  init(
    walletID: UUID,
    name: String,
    psbtBytes: Data,
    psbtBase64: String,
    signaturesCollected: Int,
    requiredSignatures: Int,
    recipientsJSON: Data,
    feeRateSatVb: String,
    totalFee: UInt64,
    changeAmount: UInt64?,
    changeAddress: String?,
    inputCount: Int,
    manualUTXOSelection: Bool,
    selectedUTXOIds: String,
    inputOutpoints: String
  ) {
    id = UUID()
    self.walletID = walletID
    self.name = String(name.prefix(Self.maxNameLength))
    self.psbtBytes = psbtBytes
    self.psbtBase64 = psbtBase64
    self.signaturesCollected = signaturesCollected
    self.requiredSignatures = requiredSignatures
    createdAt = Date()
    updatedAt = Date()
    self.recipientsJSON = recipientsJSON
    self.feeRateSatVb = feeRateSatVb
    self.totalFee = totalFee
    self.changeAmount = changeAmount
    self.changeAddress = changeAddress
    self.inputCount = inputCount
    self.manualUTXOSelection = manualUTXOSelection
    self.selectedUTXOIds = selectedUTXOIds
    self.inputOutpoints = inputOutpoints
  }
}

struct SavedRecipient: Codable {
  let address: String
  let amountSats: String
  let isSendMax: Bool
  let label: String
}

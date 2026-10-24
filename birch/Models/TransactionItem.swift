import Foundation

struct TransactionItem: Identifiable, Equatable {
  let id: String // txid
  let amount: Int64 // sats, positive = received, negative = sent
  let fee: UInt64? // sats
  let confirmations: UInt32
  /// False for a confirmed transaction whose count isn't known yet, because no
  /// chain tip has been seen. `confirmations` is then 1 and shouldn't be shown.
  let confirmationsKnown: Bool
  let timestamp: Date?
  let isIncoming: Bool
  let blockHeight: UInt32?
  let vsize: UInt64?
  let firstSeen: Date?
  let inputs: [TxIO]
  let outputs: [TxIO]

  /// A single input or output in a transaction
  struct TxIO: Identifiable, Equatable {
    let id = UUID()
    let address: String
    let amount: UInt64
    let prevTxid: String? // for inputs: the txid being spent
    let prevVout: UInt32? // for inputs: the vout being spent
    let isMine: Bool // whether this address belongs to the wallet

    static func == (lhs: TxIO, rhs: TxIO) -> Bool {
      lhs.address == rhs.address && lhs.amount == rhs.amount
        && lhs.prevTxid == rhs.prevTxid && lhs.prevVout == rhs.prevVout
        && lhs.isMine == rhs.isMine
    }
  }

  init(id: String, amount: Int64, fee: UInt64?, confirmations: UInt32,
       confirmationsKnown: Bool = true,
       timestamp: Date?, isIncoming: Bool, blockHeight: UInt32? = nil,
       vsize: UInt64? = nil, firstSeen: Date? = nil,
       inputs: [TxIO] = [], outputs: [TxIO] = [])
  {
    self.id = id
    self.amount = amount
    self.fee = fee
    self.confirmations = confirmations
    self.confirmationsKnown = confirmationsKnown
    self.timestamp = timestamp
    self.isIncoming = isIncoming
    self.blockHeight = blockHeight
    self.vsize = vsize
    self.firstSeen = firstSeen
    self.inputs = inputs
    self.outputs = outputs
  }

  var absoluteAmount: UInt64 {
    UInt64(abs(amount))
  }

  /// True when every input and every output belongs to this wallet,
  /// i.e. funds were moved within the wallet and only the fee left it.
  var isSelfTransfer: Bool {
    !inputs.isEmpty && !outputs.isEmpty
      && inputs.allSatisfy(\.isMine) && outputs.allSatisfy(\.isMine)
  }

  /// Amount moved within the wallet for a self-transfer (total output value).
  var selfTransferAmount: UInt64 {
    outputs.reduce(0) { $0 + $1.amount }
  }

  var isConfirmed: Bool {
    confirmations > 0
  }

  /// Confirmations for a transaction mined at `blockHeight`, counting that block,
  /// with `tipHeight` the best chain tip known (0 when none has been seen).
  /// Nil when the tip is unknown or behind the block, so the count can't be told.
  static func confirmations(blockHeight: UInt32, tipHeight: UInt32) -> UInt32? {
    guard tipHeight > 0, tipHeight >= blockHeight else { return nil }
    return tipHeight - blockHeight + 1
  }

  var truncatedTxid: String {
    guard id.count > 16 else { return id }
    return "\(id.prefix(8))...\(id.suffix(8))"
  }

  var isRbfEligible: Bool {
    !isConfirmed && !isIncoming && fee != nil
  }

  var currentFeeRate: Float? {
    guard let fee, let vsize, vsize > 0 else { return nil }
    return Float(fee) / Float(vsize)
  }
}

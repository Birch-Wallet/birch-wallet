@testable import birch
import Foundation
import Testing

struct TransactionItemSelfTransferTests {
  private func makeIO(address: String, amount: UInt64, isMine: Bool,
                      prevTxid: String? = nil, prevVout: UInt32? = nil) -> TransactionItem.TxIO
  {
    TransactionItem.TxIO(
      address: address,
      amount: amount,
      prevTxid: prevTxid,
      prevVout: prevVout,
      isMine: isMine
    )
  }

  private func makeTransaction(amount: Int64, isIncoming: Bool, fee: UInt64? = 500,
                               inputs: [TransactionItem.TxIO], outputs: [TransactionItem.TxIO]) -> TransactionItem
  {
    TransactionItem(
      id: "abc123def456",
      amount: amount,
      fee: fee,
      confirmations: 1,
      timestamp: Date(),
      isIncoming: isIncoming,
      inputs: inputs,
      outputs: outputs
    )
  }

  // MARK: - Self-Transfer Detection

  @Test func allMineInputsAndOutputsIsSelfTransfer() {
    // Consolidation: two wallet UTXOs spent to a single wallet address.
    // BDK nets this to -fee, which previously rendered as "Sent <fee>".
    let tx = makeTransaction(
      amount: -500,
      isIncoming: false,
      inputs: [
        makeIO(address: "tb1qmine1", amount: 60000, isMine: true, prevTxid: "prev1", prevVout: 0),
        makeIO(address: "tb1qmine2", amount: 40000, isMine: true, prevTxid: "prev2", prevVout: 1),
      ],
      outputs: [
        makeIO(address: "tb1qmine3", amount: 99500, isMine: true),
      ]
    )
    #expect(tx.isSelfTransfer)
    #expect(tx.selfTransferAmount == 99500, "Should show the amount moved, not the fee")
  }

  @Test func selfTransferWithMultipleOutputs() {
    // Splitting a UTXO across two wallet addresses (destination + change)
    let tx = makeTransaction(
      amount: -500,
      isIncoming: false,
      inputs: [
        makeIO(address: "tb1qmine1", amount: 100_000, isMine: true, prevTxid: "prev1", prevVout: 0),
      ],
      outputs: [
        makeIO(address: "tb1qmine2", amount: 70000, isMine: true),
        makeIO(address: "tb1qmine3", amount: 29500, isMine: true),
      ]
    )
    #expect(tx.isSelfTransfer)
    #expect(tx.selfTransferAmount == 99500)
  }

  // MARK: - Non-Self-Transfers

  @Test func externalSendWithChangeIsNotSelfTransfer() {
    // Normal send: recipient output is not ours, change output is
    let tx = makeTransaction(
      amount: -50500,
      isIncoming: false,
      inputs: [
        makeIO(address: "tb1qmine1", amount: 100_000, isMine: true, prevTxid: "prev1", prevVout: 0),
      ],
      outputs: [
        makeIO(address: "tb1qexternal", amount: 50000, isMine: false),
        makeIO(address: "tb1qchange", amount: 49500, isMine: true),
      ]
    )
    #expect(!tx.isSelfTransfer)
  }

  @Test func incomingReceiveIsNotSelfTransfer() {
    // Receive: inputs belong to the sender, one output is ours
    let tx = makeTransaction(
      amount: 25000,
      isIncoming: true,
      inputs: [
        makeIO(address: "tb1qsender", amount: 30000, isMine: false, prevTxid: "prev1", prevVout: 0),
      ],
      outputs: [
        makeIO(address: "tb1qmine1", amount: 25000, isMine: true),
        makeIO(address: "tb1qsenderchange", amount: 4500, isMine: false),
      ]
    )
    #expect(!tx.isSelfTransfer)
  }

  @Test func unresolvedInputIsNotSelfTransfer() {
    // When a previous output can't be resolved, its input defaults to
    // isMine=false, which must fail safe toward "Sent" rather than "Self Transfer"
    let tx = makeTransaction(
      amount: -500,
      isIncoming: false,
      inputs: [
        makeIO(address: "prevtxid:0", amount: 0, isMine: false, prevTxid: "prevtxid", prevVout: 0),
      ],
      outputs: [
        makeIO(address: "tb1qmine1", amount: 99500, isMine: true),
      ]
    )
    #expect(!tx.isSelfTransfer)
  }

  @Test func emptyInputsAndOutputsIsNotSelfTransfer() {
    // TransactionItems built without input/output detail (e.g. the send-review
    // draft in SendViewModel) must never classify as self-transfer
    let tx = makeTransaction(amount: -10000, isIncoming: false, inputs: [], outputs: [])
    #expect(!tx.isSelfTransfer)
  }
}

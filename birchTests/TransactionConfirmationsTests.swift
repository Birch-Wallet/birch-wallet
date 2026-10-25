@testable import birch
import Foundation
import Testing

struct TransactionConfirmationsTests {
  @Test func `counts the mining block`() {
    #expect(TransactionItem.confirmations(blockHeight: 100, tipHeight: 100) == 1)
    #expect(TransactionItem.confirmations(blockHeight: 100, tipHeight: 105) == 6)
  }

  @Test func `unknown without A tip`() {
    // A new wallet before any tip is seen: confirmed, but the depth is unknown
    #expect(TransactionItem.confirmations(blockHeight: 100, tipHeight: 0) == nil)
  }

  @Test func `unknown when the tip is behind the block`() {
    // A stale tip can't tell the depth of a newer block
    #expect(TransactionItem.confirmations(blockHeight: 100, tipHeight: 99) == nil)
  }

  @Test func `defaults to known`() {
    let tx = TransactionItem(id: "abc", amount: 1000, fee: nil, confirmations: 3, timestamp: nil, isIncoming: true)
    #expect(tx.confirmationsKnown)
    #expect(tx.isConfirmed)
  }
}

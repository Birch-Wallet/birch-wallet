@testable import birch
import Foundation
import Testing

@MainActor
struct BumpFeeViewModelTests {
  /// Helper to create a test transaction
  private func makeTransaction(fee: UInt64 = 500, vsize: UInt64 = 200) -> TransactionItem {
    TransactionItem(
      id: "abc123def456",
      amount: -10000,
      fee: fee,
      confirmations: 0,
      timestamp: nil,
      isIncoming: false,
      vsize: vsize
    )
  }

  // MARK: - Initial State

  @Test func initialStep() {
    let vm = BumpFeeViewModel(transaction: makeTransaction())
    #expect(vm.currentStep == .feeInput)
  }

  // MARK: - Fee Rate Validation (Integer-Only)

  @Test func isValidFeeRateRequiresHigherThanOriginal() {
    // Transaction with fee=500 sats, vsize=200 → feeRate = 2.5 sat/vB
    let vm = BumpFeeViewModel(transaction: makeTransaction(fee: 500, vsize: 200))

    // Rate must exceed original 2.5 sat/vB
    vm.newFeeRate = "2"
    #expect(vm.isValidFeeRate == false, "2 is not higher than 2.5")

    vm.newFeeRate = "3"
    #expect(vm.isValidFeeRate == true, "3 is higher than 2.5")

    vm.newFeeRate = "10"
    #expect(vm.isValidFeeRate == true, "10 is higher than 2.5")
  }

  @Test func feeRateEdgeCases() {
    // Transaction with fee=500, vsize=200 → originalFeeRate = 2.5 sat/vB
    let vm = BumpFeeViewModel(transaction: makeTransaction())

    vm.newFeeRate = "0"
    #expect(vm.isValidFeeRate == false, "0 is below minimum")

    vm.newFeeRate = "0.5"
    #expect(vm.isValidFeeRate == false, "0.5 is lower than original rate (2.5 sat/vB)")

    vm.newFeeRate = "-1"
    #expect(vm.isValidFeeRate == false, "Negative should be invalid")

    vm.newFeeRate = "abc"
    #expect(vm.isValidFeeRate == false, "Non-numeric should be invalid")

    vm.newFeeRate = ""
    #expect(vm.isValidFeeRate == false, "Empty should be invalid")
  }

  @Test func feeRateValueParsesAsDouble() {
    let vm = BumpFeeViewModel(transaction: makeTransaction())

    vm.newFeeRate = "5"
    #expect(vm.feeRateValue == 5.0)

    vm.newFeeRate = "abc"
    #expect(vm.feeRateValue == 0, "Invalid input defaults to 0")

    vm.newFeeRate = ""
    #expect(vm.feeRateValue == 0, "Empty defaults to 0")
  }

  // MARK: - Needs More Signatures Boundary

  @Test func needsMoreSignatures() {
    let vm = BumpFeeViewModel(transaction: makeTransaction())
    vm.requiredSignatures = 2

    vm.signaturesCollected = 0
    #expect(vm.needsMoreSignatures == true)

    vm.signaturesCollected = 1
    #expect(vm.needsMoreSignatures == true)

    vm.signaturesCollected = 2
    #expect(vm.needsMoreSignatures == false)

    vm.signaturesCollected = 3
    #expect(vm.needsMoreSignatures == false)
  }

  // MARK: - Signature Progress

  @Test func signatureProgressString() {
    let vm = BumpFeeViewModel(transaction: makeTransaction())
    vm.requiredSignatures = 3
    vm.signaturesCollected = 1
    #expect(vm.signatureProgress == "1 of 3 signatures")
  }

  // MARK: - Fee Rate Without Original

  @Test func isValidFeeRateWithoutOriginal() {
    // Transaction without vsize → no originalFeeRate
    let tx = TransactionItem(
      id: "test",
      amount: -5000,
      fee: 200,
      confirmations: 0,
      timestamp: nil,
      isIncoming: false
    )
    let vm = BumpFeeViewModel(transaction: tx)
    #expect(vm.originalFeeRate == nil)

    vm.newFeeRate = "1"
    #expect(vm.isValidFeeRate == true, "Any rate > 0 is valid without original")
  }

  @Test func feeRateAboveMaximumIsInvalid() {
    let vm = BumpFeeViewModel(transaction: makeTransaction())

    vm.newFeeRate = "10000"
    #expect(vm.isValidFeeRate == true, "The maximum itself is allowed")

    vm.newFeeRate = "20000"
    #expect(vm.isValidFeeRate == false)
    #expect(vm.feeRateValue == 0)

    vm.newFeeRate = String(repeating: "9", count: 400)
    #expect(vm.isValidFeeRate == false, "A huge rate must not parse to infinity")
  }
}

@testable import birch
import Foundation
import Testing

@MainActor
struct SendViewModelTests {
  // MARK: - Initial State

  @Test func initialStepIsRecipients() {
    let vm = SendViewModel()
    #expect(vm.currentStep == .recipients)
  }

  // MARK: - Balance Validation

  @Test func tryReviewBlocksWhenBalanceExceeded() {
    let vm = SendViewModel()
    vm.availableBalance = 1000
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "950")]
    vm.feeRateSatVb = "10"
    // With high fee rate, amount + fees should exceed 1000
    vm.tryReview()
    #expect(vm.currentStep == .recipients)
  }

  @Test func tryReviewAllowsWhenBalanceNotExceeded() {
    let vm = SendViewModel()
    vm.availableBalance = 100_000
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "1000")]
    vm.feeRateSatVb = "1"
    vm.tryReview()
    #expect(vm.showValidationErrors == false)
  }

  @Test func isBalanceExceededSkipsSendMax() {
    let vm = SendViewModel()
    vm.availableBalance = 100
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "99999", isSendMax: true)]
    #expect(!vm.isBalanceExceeded)
  }

  @Test func isBalanceExceededWithManualUTXOSelection() {
    let vm = SendViewModel()
    vm.manualUTXOSelection = true
    // No UTXOs selected, so selectedUTXOTotal = 0
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "5000")]
    vm.feeRateSatVb = "1"
    #expect(vm.isBalanceExceeded)
  }

  // MARK: - Existing Validation (regression tests)

  @Test func tryReviewBlocksEmptyAddress() {
    let vm = SendViewModel()
    vm.availableBalance = 100_000
    vm.recipients = [Recipient(address: "", amountSats: "1000")]
    vm.feeRateSatVb = "1"
    vm.tryReview()
    #expect(vm.currentStep == .recipients)
  }

  @Test func tryReviewBlocksInvalidFeeRate() {
    let vm = SendViewModel()
    vm.availableBalance = 100_000
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "1000")]
    vm.feeRateSatVb = "0"
    vm.tryReview()
    #expect(vm.currentStep == .recipients)
  }

  @Test func tryReviewBlocksZeroAmount() {
    let vm = SendViewModel()
    vm.availableBalance = 100_000
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "0")]
    vm.feeRateSatVb = "1"
    vm.tryReview()
    #expect(vm.currentStep == .recipients)
  }

  @Test func totalSendAmountSumsRecipients() {
    let vm = SendViewModel()
    vm.recipients = [
      Recipient(address: "tb1q1", amountSats: "1000"),
      Recipient(address: "tb1q2", amountSats: "2000"),
      Recipient(address: "tb1q3", amountSats: "3000"),
    ]
    #expect(vm.totalSendAmount == 6000)
  }

  // MARK: - Frozen UTXO Guard

  @Test func frozenUTXOGuardRejectsFrozenInput() {
    let vm = SendViewModel()
    vm.frozenOutpoints = ["abc123:0"]
    let error = vm.validateUTXOInputs(outpoints: [(txid: "abc123", vout: 0)])
    #expect(error != nil)
    #expect(error?.contains("frozen") == true)
  }

  @Test func frozenUTXOGuardAllowsUnfrozenInput() {
    let vm = SendViewModel()
    vm.frozenOutpoints = ["abc123:0"]
    let error = vm.validateUTXOInputs(outpoints: [(txid: "def456", vout: 1)])
    #expect(error == nil)
  }

  @Test func frozenUTXOGuardAllowsNilOutpoints() {
    let vm = SendViewModel()
    vm.frozenOutpoints = ["abc123:0"]
    let error = vm.validateUTXOInputs(outpoints: nil)
    #expect(error == nil)
  }

  // MARK: - Needs More Signatures Boundary

  @Test func needsMoreSignaturesBoundary() {
    let vm = SendViewModel()
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

  // MARK: - Reset

  @Test func resetClearsAllState() {
    let vm = SendViewModel()
    // Set a bunch of state
    vm.currentStep = .broadcast
    vm.recipients = [Recipient(address: "tb1q1", amountSats: "1000")]
    vm.feeRateSatVb = "10"
    vm.psbtBase64 = "somebase64"
    vm.psbtBytes = Data([0x01, 0x02])
    vm.totalFee = 500
    vm.changeAmount = 200
    vm.changeAddress = "tb1qchange"
    vm.inputCount = 3
    vm.signaturesCollected = 2
    vm.broadcastTxid = "abc123"
    vm.finalizedTxBytes = Data([0x03])
    vm.errorMessage = "some error"
    vm.isProcessing = true
    vm.showValidationErrors = true
    vm.showExportQR = true
    vm.showAddressScanner = true
    vm.manualUTXOSelection = true
    vm.selectedUTXOIds = ["utxo1"]
    vm.showUTXOPicker = true

    vm.reset()

    #expect(vm.currentStep == .recipients)
    #expect(vm.recipients.count == 1)
    #expect(vm.recipients[0].address == "")
    #expect(vm.feeRateSatVb == "")
    #expect(vm.psbtBase64 == "")
    #expect(vm.psbtBytes.isEmpty)
    #expect(vm.totalFee == 0)
    #expect(vm.changeAmount == nil)
    #expect(vm.changeAddress == nil)
    #expect(vm.inputCount == 0)
    #expect(vm.signaturesCollected == 0)
    #expect(vm.broadcastTxid == "")
    #expect(vm.finalizedTxBytes.isEmpty)
    #expect(vm.errorMessage == nil)
    #expect(vm.isProcessing == false)
    #expect(vm.showValidationErrors == false)
    #expect(vm.showExportQR == false)
    #expect(vm.showAddressScanner == false)
    #expect(vm.manualUTXOSelection == false)
    #expect(vm.selectedUTXOIds.isEmpty)
    #expect(vm.showUTXOPicker == false)
  }

  // MARK: - Fee Rate Validation

  @Test func feeRateEdgeCases() {
    let vm = SendViewModel()

    vm.feeRateSatVb = "0"
    #expect(vm.isValidFeeRate == false, "0 is below minimum")

    vm.feeRateSatVb = "0.5"
    #expect(vm.isValidFeeRate == true, "0.5 sat/vB is a valid decimal rate")

    vm.feeRateSatVb = "-1"
    #expect(vm.isValidFeeRate == false, "Negative should be invalid")

    vm.feeRateSatVb = "abc"
    #expect(vm.isValidFeeRate == false, "Non-numeric should be invalid")

    vm.feeRateSatVb = ""
    #expect(vm.isValidFeeRate == false, "Empty should be invalid")

    vm.feeRateSatVb = "1"
    #expect(vm.isValidFeeRate == true, "1 is valid")

    vm.feeRateSatVb = "1000"
    #expect(vm.isValidFeeRate == true, "High rate is valid")
  }

  @Test func feeRateValueParsesAsDouble() {
    let vm = SendViewModel()

    vm.feeRateSatVb = "5"
    #expect(vm.feeRateValue == 5.0)

    vm.feeRateSatVb = "abc"
    #expect(vm.feeRateValue == 0, "Invalid input defaults to 0")

    vm.feeRateSatVb = "0.5"
    #expect(vm.feeRateValue == 0.5, "Decimal input parses correctly")
  }

  // MARK: - BIP-21 URI Parsing

  @Test func parseBIP21PlainAddress() {
    let vm = SendViewModel()
    vm.recipients = [Recipient()]
    vm.parseBIP21("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", forRecipientAt: 0)
    #expect(vm.recipients[0].address == "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
    #expect(vm.recipients[0].amountSats == "")
  }

  @Test func parseBIP21WithAmount() {
    let vm = SendViewModel()
    vm.recipients = [Recipient()]
    vm.parseBIP21("bitcoin:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx?amount=0.001", forRecipientAt: 0)
    #expect(vm.recipients[0].address == "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
    #expect(vm.recipients[0].amountSats == "100000") // 0.001 BTC = 100,000 sats
  }

  @Test func parseBIP21WithoutAmount() {
    let vm = SendViewModel()
    vm.recipients = [Recipient()]
    vm.parseBIP21("bitcoin:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", forRecipientAt: 0)
    #expect(vm.recipients[0].address == "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
  }

  // MARK: - Manual UTXO Selection

  @Test func manualUTXOSelectionWithNoSelection() {
    let vm = SendViewModel()
    vm.manualUTXOSelection = true
    // No UTXOs selected → selectedUTXOTotal = 0
    #expect(vm.selectedUTXOTotal == 0)
    // Any positive amount should exceed balance
    vm.recipients = [Recipient(address: "tb1qtest", amountSats: "100")]
    vm.feeRateSatVb = "1"
    #expect(vm.isBalanceExceeded)
  }

  @Test func frozenUTXOMixedInputs() {
    let vm = SendViewModel()
    vm.frozenOutpoints = ["frozen1:0", "frozen2:1"]
    // Mix of frozen and unfrozen
    let outpoints: [(txid: String, vout: UInt32)] = [
      (txid: "unfrozen1", vout: 0),
      (txid: "frozen1", vout: 0),
      (txid: "unfrozen2", vout: 1),
    ]
    let error = vm.validateUTXOInputs(outpoints: outpoints)
    #expect(error != nil, "Should reject when any frozen UTXO is in inputs")
    #expect(error?.contains("1 frozen") == true)
  }

  // MARK: - Create PSBT Validation

  @Test func createPSBTRejectsInvalidRecipients() async {
    let vm = SendViewModel()
    vm.availableBalance = 100_000

    // Empty address
    vm.recipients = [Recipient(address: "", amountSats: "1000")]
    await vm.createPSBT()
    #expect(vm.errorMessage == "Invalid recipient or amount")
    #expect(vm.currentStep == .recipients)

    vm.errorMessage = nil

    // Zero amount (non-sendmax)
    vm.recipients = [Recipient(address: "tb1qtest", amountSats: "0")]
    await vm.createPSBT()
    #expect(vm.errorMessage == "Invalid recipient or amount")
  }

  // MARK: - Has Any Input Detection

  @Test func hasAnyInputDetection() {
    let vm = SendViewModel()

    // Default empty state
    vm.recipients = [Recipient()]
    #expect(vm.hasAnyInput == false)

    // Address filled
    vm.recipients = [Recipient(address: "tb1q1")]
    #expect(vm.hasAnyInput == true)

    // Amount filled
    vm.recipients = [Recipient(amountSats: "100")]
    #expect(vm.hasAnyInput == true)

    // Label filled
    vm.recipients = [Recipient(label: "payment")]
    #expect(vm.hasAnyInput == true)

    // Manual UTXO mode
    vm.recipients = [Recipient()]
    vm.manualUTXOSelection = true
    #expect(vm.hasAnyInput == true)
  }

  // MARK: - Signature Progress

  @Test func signatureProgressString() {
    let vm = SendViewModel()
    vm.requiredSignatures = 3
    vm.signaturesCollected = 1
    #expect(vm.signatureProgress == "1 of 3 signatures")
  }

  // MARK: - Finalize Once Guard

  @Test func finalizeTxSkipsWhenAlreadyFinalized() {
    let vm = SendViewModel()
    vm.finalizedTxBytes = Data([0x01, 0x02, 0x03])
    // finalizeTx should be a no-op when already finalized
    vm.finalizeTx()
    #expect(vm.finalizedTxBytes == Data([0x01, 0x02, 0x03]))
    #expect(vm.errorMessage == nil)
  }

  // MARK: - Self Recipient Detection

  @Test func isSelfRecipientChecksWalletOwnership() {
    let mock = MockBitcoinService()
    mock.walletAddresses = ["tb1qmine"]
    let vm = SendViewModel(bitcoinService: mock)

    #expect(vm.isSelfRecipient(Recipient(address: "tb1qmine", amountSats: "1000")))
    #expect(vm.isSelfRecipient(Recipient(address: "  tb1qmine  ", amountSats: "1000")),
            "whitespace should be trimmed before ownership check")
    #expect(!vm.isSelfRecipient(Recipient(address: "tb1qexternal", amountSats: "1000")))
    #expect(!vm.isSelfRecipient(Recipient(address: "", amountSats: "1000")),
            "empty address must never classify as self")
  }
}

@testable import birch
import Foundation
import Testing

@MainActor
struct SigningFlowTests {
  // MARK: - Helpers

  private func makeMockService() -> MockBitcoinService {
    let mock = MockBitcoinService()
    mock.requiredSignatures = 2
    return mock
  }

  private func makePSBTResult(base64: String = "dGVzdA==") -> BitcoinService.PSBTResult {
    BitcoinService.PSBTResult(
      base64: base64,
      bytes: Data(base64Encoded: base64)!,
      fee: 500,
      changeAmount: 1000,
      changeAddress: "tb1qchange",
      inputCount: 1
    )
  }

  private func criticalFinding(_ message: String = "Input lies about its amount") -> PSBTFinding {
    .critical(PSBTFinding.Code.inputAmountMismatch, outpoint: "aa:0", message)
  }

  private func warningFinding() -> PSBTFinding {
    .warning(PSBTFinding.Code.inputAmountUnverifiable, outpoint: "bb:1", "Could not verify")
  }

  // MARK: - Verification of merged PSBTs

  @Test func handleSignedPSBTRejectsMergeThatFailsVerification() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2
    vm.signaturesCollected = 0
    vm.psbtBytes = Data([0x01])
    vm.psbtBase64 = "AQ=="
    vm.currentStep = .psbtScan

    // Combine succeeds, but the merged PSBT contradicts wallet state.
    mock.combinePSBTsResult = ("bmV3", Data([0x02]))
    mock.verifyPSBTResult = [criticalFinding()]

    await vm.handleSignedPSBT(Data([0x03]))

    #expect(vm.psbtBytes == Data([0x01]), "Merged bytes must not be kept")
    #expect(vm.psbtBase64 == "AQ==")
    #expect(vm.signaturesCollected == 0)
    #expect(vm.currentStep == .psbtScan, "Should stay on the scan step")
    #expect(vm.errorMessage == "Input lies about its amount")
    #expect(!vm.isProcessing)
  }

  @Test func handleSignedPSBTKeepsMergeOnWarningsAlone() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2
    vm.signaturesCollected = 0
    vm.inputCount = 2
    vm.psbtBytes = Data([0x01])
    vm.currentStep = .psbtScan

    mock.combinePSBTsResult = ("bmV3", Data([0x02]))
    mock.verifyPSBTResult = [warningFinding()]

    await vm.handleSignedPSBT(Data([0x03]))

    #expect(vm.psbtBytes == Data([0x02]), "Warnings must not block the merge")
    #expect(vm.signaturesCollected == 1)
    #expect(vm.currentStep == .psbtDisplay)
    #expect(vm.errorMessage == nil)
    #expect(vm.psbtVerification == .partiallyVerified(verified: 1, unverified: 1))
  }

  @Test func handleSignedPSBTRecordsVerifiedStateOnCleanMerge() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2
    vm.inputCount = 3
    vm.psbtBytes = Data([0x01])

    mock.combinePSBTsResult = ("bmV3", Data([0x02]))
    mock.verifyPSBTResult = []

    await vm.handleSignedPSBT(Data([0x03]))

    #expect(vm.psbtVerification == .verified(inputs: 3))
  }

  @Test func bumpFeeHandleSignedPSBTRejectsFailedVerification() async {
    let mock = makeMockService()
    let tx = TransactionItem(
      id: "test_tx", amount: -5000, fee: 200,
      confirmations: 0, timestamp: nil, isIncoming: false, vsize: 100
    )
    let vm = BumpFeeViewModel(transaction: tx, bitcoinService: mock)
    vm.psbtBytes = Data([0x01])
    vm.currentStep = .psbtScan

    mock.combinePSBTsResult = ("bmV3", Data([0x02]))
    mock.verifyPSBTResult = [criticalFinding("Bump PSBT lies")]

    await vm.handleSignedPSBT(Data([0x03]))

    #expect(vm.psbtBytes == Data([0x01]))
    #expect(vm.currentStep == .psbtScan)
    #expect(vm.errorMessage == "Bump PSBT lies")
  }

  @Test func duplicateScanTellsTheUser() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.psbtBytes = Data([0x01])
    vm.currentStep = .psbtScan

    // Same bytes back → nothing new in this PSBT
    mock.combinePSBTsResult = ("AQ==", Data([0x01]))

    await vm.handleSignedPSBT(Data([0x01]))

    #expect(vm.errorMessage != nil, "A no-op scan must not look like success")
    #expect(vm.signaturesCollected == 0)
    #expect(vm.currentStep == .psbtScan)
  }

  // MARK: - SendViewModel + Mock: handleSignedPSBT

  @Test func handleSignedPSBTAdvancesState() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2
    vm.signaturesCollected = 0
    vm.psbtBytes = Data([0x01])
    vm.currentStep = .psbtScan

    // Mock returns different bytes → signature is new
    mock.combinePSBTsResult = ("bmV3", Data([0x02]))

    await vm.handleSignedPSBT(Data([0x03]))

    #expect(vm.signaturesCollected == 1)
    #expect(vm.currentStep == .psbtDisplay, "Needs more sigs → back to display")
    #expect(vm.psbtBytes == Data([0x02]))
  }

  @Test func handleSignedPSBTDuplicateDoesNotAdvance() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2
    vm.signaturesCollected = 0
    vm.psbtBytes = Data([0x01])

    // Mock returns same bytes → duplicate signature
    mock.combinePSBTsResult = ("AQ==", Data([0x01]))

    await vm.handleSignedPSBT(Data([0x01]))

    #expect(vm.signaturesCollected == 0, "Duplicate sig should not advance counter")
  }

  @Test func handleSignedPSBTLastSignatureGoesToBroadcast() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2
    vm.signaturesCollected = 1
    vm.psbtBytes = Data([0x01])

    mock.combinePSBTsResult = ("Ag==", Data([0x02]))

    await vm.handleSignedPSBT(Data([0x03]))

    #expect(vm.signaturesCollected == 2)
    #expect(vm.currentStep == .broadcast, "All sigs collected → broadcast")
  }

  @Test func handleSignedPSBTErrorSetsMessage() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.psbtBytes = Data([0x01])
    vm.currentStep = .psbtScan

    mock.combinePSBTsError = AppError.psbtCombineFailed("Invalid PSBT")

    await vm.handleSignedPSBT(Data([0x02]))

    #expect(vm.errorMessage != nil)
    #expect(vm.signaturesCollected == 0)
  }

  // MARK: - SendViewModel + Mock: broadcast

  @Test func broadcastSuccessSetsTransactionId() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.psbtBytes = Data([0x01])

    mock.broadcastPSBTResult = "txid_abc123"

    await vm.broadcast()

    #expect(vm.broadcastTxid == "txid_abc123")
    #expect(vm.errorMessage == nil)
    #expect(mock.broadcastPSBTCallCount == 1)
  }

  @Test func broadcastFailureSetsError() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.psbtBytes = Data([0x01])

    mock.broadcastPSBTError = AppError.broadcastFailed("Network error")

    await vm.broadcast()

    #expect(vm.broadcastTxid == "")
    #expect(vm.errorMessage != nil)
  }

  @Test func broadcastSetsTxidOnSuccess() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.psbtBytes = Data([0x01])
    mock.broadcastPSBTResult = "txid_abc"

    await vm.broadcast()

    #expect(vm.broadcastTxid == "txid_abc")
    // Sync is now triggered by the View layer (BroadcastResultView) on navigation,
    // not by the ViewModel after broadcast
    #expect(mock.syncCallCount == 0)
  }

  // MARK: - SendViewModel + Mock: createPSBT

  @Test func createPSBTPopulatesDetails() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "1000")]
    vm.feeRateSatVb = "1"

    mock.createPSBTResult = makePSBTResult()

    await vm.createPSBT()

    #expect(vm.totalFee == 500)
    #expect(vm.changeAmount == 1000)
    #expect(vm.changeAddress == "tb1qchange")
    #expect(vm.inputCount == 1)
    #expect(vm.currentStep == .psbtDisplay)
    #expect(vm.signaturesCollected == 0)
  }

  @Test func createPSBTRejectsEmptyAddressEarly() async {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.recipients = [Recipient(address: "", amountSats: "1000")]

    await vm.createPSBT()

    #expect(vm.errorMessage == "Invalid recipient or amount")
    #expect(mock.createPSBTCallCount == 0, "Should not call service with invalid input")
  }

  // MARK: - Full Flow State Machine

  @Test func fullFlowStateMachine() async throws {
    let mock = makeMockService()
    let vm = SendViewModel(bitcoinService: mock)
    vm.requiredSignatures = 2

    // Step 1: Start at recipients
    #expect(vm.currentStep == .recipients)

    // Step 2: Create PSBT → moves to psbtDisplay
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "1000")]
    vm.feeRateSatVb = "1"
    mock.createPSBTResult = makePSBTResult(base64: "cHNidDE=")
    await vm.createPSBT()
    #expect(vm.currentStep == .psbtDisplay)

    // Step 3: Handle first signature → still needs more
    mock.combinePSBTsResult = try ("cHNidDI=", #require(Data(base64Encoded: "cHNidDI=")))
    await vm.handleSignedPSBT(Data([0x01]))
    #expect(vm.signaturesCollected == 1)
    #expect(vm.currentStep == .psbtDisplay)

    // Step 4: Handle second signature → moves to broadcast
    mock.combinePSBTsResult = try ("cHNidDM=", #require(Data(base64Encoded: "cHNidDM=")))
    await vm.handleSignedPSBT(Data([0x02]))
    #expect(vm.signaturesCollected == 2)
    #expect(vm.currentStep == .broadcast)

    // Step 5: Broadcast
    mock.broadcastPSBTResult = "final_txid"
    await vm.broadcast()
    #expect(vm.broadcastTxid == "final_txid")
  }

  // MARK: - BumpFeeViewModel + Mock

  @Test func bumpFeeHandleSignedPSBTDuplicateDoesNotAdvance() async {
    let mock = makeMockService()
    let tx = TransactionItem(
      id: "test_tx", amount: -5000, fee: 200,
      confirmations: 0, timestamp: nil, isIncoming: false, vsize: 100
    )
    let vm = BumpFeeViewModel(transaction: tx, bitcoinService: mock)
    vm.psbtBytes = Data([0x01])
    vm.signaturesCollected = 0

    // Same bytes back → duplicate
    mock.combinePSBTsResult = ("AQ==", Data([0x01]))
    await vm.handleSignedPSBT(Data([0x01]))

    #expect(vm.signaturesCollected == 0, "Duplicate sig should not advance counter")
  }

  @Test func bumpFeeBroadcastTriggersSyncOnSuccess() async {
    let mock = makeMockService()
    let tx = TransactionItem(
      id: "test_tx", amount: -5000, fee: 200,
      confirmations: 0, timestamp: nil, isIncoming: false, vsize: 100
    )
    let vm = BumpFeeViewModel(transaction: tx, bitcoinService: mock)
    vm.psbtBytes = Data([0x01])
    mock.broadcastPSBTResult = "bump_txid"

    await vm.broadcast()

    try? await Task.sleep(for: .milliseconds(100))
    #expect(vm.broadcastTxid == "bump_txid")
    #expect(mock.syncCallCount >= 1)
  }
}

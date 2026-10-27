@testable import birch
import Foundation
import SwiftData
import Testing

/// A PSBT, its signatures and its fee rates stay with the wallet they came from,
/// whichever wallet is loaded later.
@MainActor
struct WalletIsolationTests {
  private let walletA = UUID()
  private let walletB = UUID()

  private func makeContext() throws -> ModelContext {
    let schema = Schema([SavedPSBT.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    return ModelContext(container)
  }

  private func makePSBTResult() -> BitcoinService.PSBTResult {
    BitcoinService.PSBTResult(
      base64: Data([0x70, 0x73, 0x62, 0x74]).base64EncodedString(),
      bytes: Data([0x70, 0x73, 0x62, 0x74]),
      fee: 500,
      changeAmount: nil,
      changeAddress: nil,
      inputCount: 1,
    )
  }

  private func makeSavedPSBT(walletID: UUID) -> SavedPSBT {
    SavedPSBT(
      walletID: walletID,
      name: "Saved",
      psbtBytes: Data([0x70, 0x73, 0x62, 0x74]),
      psbtBase64: "cHNidA==",
      signaturesCollected: 0,
      requiredSignatures: 2,
      recipientsJSON: Data(),
      feeRateSatVb: "2",
      totalFee: 500,
      changeAmount: nil,
      changeAddress: nil,
      inputCount: 1,
      manualUTXOSelection: false,
      selectedUTXOIds: "",
      inputOutpoints: "",
    )
  }

  /// A Send view model holding a PSBT built while wallet A was loaded
  private func sendViewModelWithPSBT(_ service: MockBitcoinService) async -> SendViewModel {
    service.currentWalletID = walletA
    service.createPSBTResult = makePSBTResult()
    let vm = SendViewModel(bitcoinService: service)
    vm.recipients = [Recipient(address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", amountSats: "1000")]
    vm.feeRateSatVb = "2"
    await vm.createPSBT()
    return vm
  }

  // MARK: - Send

  @Test func `a built PSBT records the wallet that built it`() async {
    let vm = await sendViewModelWithPSBT(MockBitcoinService())
    #expect(vm.psbtWalletID == walletA)
  }

  @Test func `saving files the PSBT under the wallet that built it`() async throws {
    let service = MockBitcoinService()
    let vm = await sendViewModelWithPSBT(service)
    service.currentWalletID = walletB

    let context = try makeContext()
    vm.savePSBT(name: "Draft", context: context)

    let saved = try context.fetch(FetchDescriptor<SavedPSBT>())
    #expect(saved.map(\.walletID) == [walletA])
  }

  @Test func `a PSBT with no wallet recorded is not saved`() throws {
    let vm = SendViewModel(bitcoinService: MockBitcoinService())
    vm.psbtBytes = Data([0x70, 0x73, 0x62, 0x74])
    let context = try makeContext()
    vm.savePSBT(name: "Orphan", context: context)
    #expect(try context.fetch(FetchDescriptor<SavedPSBT>()).isEmpty)
  }

  @Test func `a loaded saved PSBT belongs to the wallet it was saved under`() {
    let service = MockBitcoinService()
    service.currentWalletID = walletB
    let vm = SendViewModel(bitcoinService: service)
    vm.loadSavedPSBT(makeSavedPSBT(walletID: walletA))
    #expect(vm.psbtWalletID == walletA)
  }

  @Test func `a signature for another wallets PSBT is not merged`() async {
    let service = MockBitcoinService()
    let vm = await sendViewModelWithPSBT(service)
    service.currentWalletID = walletB

    await vm.handleSignedPSBT(Data([0x01]))
    #expect(service.combinePSBTsCallCount == 0)
    #expect(vm.errorMessage == vm.otherWalletPSBTMessage)
  }

  @Test func `another wallets PSBT is not broadcast`() async {
    let service = MockBitcoinService()
    service.broadcastPSBTResult = "txid"
    let vm = await sendViewModelWithPSBT(service)
    service.currentWalletID = walletB

    await vm.broadcast()
    #expect(service.broadcastPSBTCallCount == 0)
    #expect(vm.broadcastTxid.isEmpty)
  }

  @Test func `the PSBT for the loaded wallet is still broadcast`() async {
    let service = MockBitcoinService()
    service.broadcastPSBTResult = "txid"
    let vm = await sendViewModelWithPSBT(service)

    await vm.broadcast()
    #expect(service.broadcastPSBTCallCount == 1)
    #expect(vm.broadcastTxid == "txid")
  }

  @Test func `reset forgets the PSBTs wallet`() async {
    let vm = await sendViewModelWithPSBT(MockBitcoinService())
    vm.reset()
    #expect(vm.psbtWalletID == nil)
  }

  // MARK: - Fee rates

  @Test func `fee rates fetched for a wallet no longer loaded are ignored`() async {
    let service = MockBitcoinService()
    service.getFeeRatesError = CancellationError()
    let vm = SendViewModel(bitcoinService: service)
    await vm.fetchFeeRates()
    #expect(vm.recommendedFees == nil)
    #expect(vm.feeRateSatVb.isEmpty)
  }

  @Test func `a failed fee fetch still falls back`() async {
    let service = MockBitcoinService()
    service.getFeeRatesError = AppError.electrumConnectionFailed("down")
    let vm = SendViewModel(bitcoinService: service)
    await vm.fetchFeeRates()
    #expect(vm.recommendedFees?.medium == BitcoinService.RecommendedFees.fallback.medium)
  }

  @Test func `bump fee ignores fee rates for a wallet no longer loaded`() async {
    let service = MockBitcoinService()
    service.getFeeRatesError = CancellationError()
    let vm = BumpFeeViewModel(transaction: makeTransaction(), bitcoinService: service)
    await vm.fetchFeeRates()
    #expect(vm.recommendedFees == nil)
  }

  // MARK: - Bump fee

  private func makeTransaction() -> TransactionItem {
    TransactionItem(id: "abc123", amount: -10000, fee: 500, confirmations: 0, timestamp: nil, isIncoming: false, vsize: 200)
  }

  @Test func `a bump belongs to the wallet holding the transaction`() async throws {
    let service = MockBitcoinService()
    service.currentWalletID = walletA
    service.createBumpFeePSBTResult = makePSBTResult()
    let vm = BumpFeeViewModel(transaction: makeTransaction(), bitcoinService: service)
    #expect(vm.psbtWalletID == walletA)

    vm.newFeeRate = "5"
    await vm.createBumpPSBT()
    service.currentWalletID = walletB

    let context = try makeContext()
    vm.savePSBT(name: "Bump", context: context)
    let saved = try context.fetch(FetchDescriptor<SavedPSBT>())
    #expect(saved.map(\.walletID) == [walletA])
  }

  @Test func `a bump is not built or signed for another wallet`() async {
    let service = MockBitcoinService()
    service.currentWalletID = walletA
    service.createBumpFeePSBTResult = makePSBTResult()
    let vm = BumpFeeViewModel(transaction: makeTransaction(), bitcoinService: service)
    service.currentWalletID = walletB

    vm.newFeeRate = "5"
    await vm.createBumpPSBT()
    #expect(vm.psbtBytes.isEmpty)
    #expect(vm.errorMessage == vm.otherWalletPSBTMessage)

    await vm.handleSignedPSBT(Data([0x01]))
    #expect(service.combinePSBTsCallCount == 0)
  }

  @Test func `a resumed bump belongs to the wallet it was saved under`() {
    let service = MockBitcoinService()
    service.currentWalletID = walletB
    let vm = BumpFeeViewModel(savedPSBT: makeSavedPSBT(walletID: walletA), bitcoinService: service)
    #expect(vm.psbtWalletID == walletA)
    #expect(!vm.isPSBTForLoadedWallet)
  }
}

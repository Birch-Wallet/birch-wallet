@testable import birch
import Foundation
import SwiftData
import Testing

/// Saving a PSBT to SwiftData and loading it back must return byte-identical data,
/// including every input's non_witness_utxo.
@MainActor
struct SavedPSBTRoundTripTests {
  private func loadFixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: RoundTripBundleToken.self)
    let path = try #require(bundle.path(forResource: name, ofType: "txt"))
    let base64 = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(Data(base64Encoded: base64))
  }

  private func nonWitnessUtxoCount(_ data: Data) throws -> Int {
    try PSBTParser.parse(data).records.count(where: {
      if case .input = $0.map {
        return $0.keyType == 0x00
      }
      return false
    })
  }

  private func makeSaved(_ bytes: Data) -> SavedPSBT {
    // Mirrors SendViewModel.savePSBT's new-record path
    SavedPSBT(
      walletID: UUID(),
      name: "round trip",
      psbtBytes: bytes,
      psbtBase64: bytes.base64EncodedString(),
      signaturesCollected: 0,
      requiredSignatures: 2,
      recipientsJSON: Data("[]".utf8),
      feeRateSatVb: "2",
      totalFee: 0,
      changeAmount: nil,
      changeAddress: nil,
      inputCount: 2,
      manualUTXOSelection: false,
      selectedUTXOIds: "",
      inputOutpoints: ""
    )
  }

  @Test func swiftDataRoundTripKeepsNonWitnessUtxo() throws {
    let original = try loadFixture("test_psbt_nonwitness")
    let before = try nonWitnessUtxoCount(original)
    #expect(before > 0)

    let schema = Schema([SavedPSBT.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])

    let writeContext = ModelContext(container)
    let saved = makeSaved(original)
    let id = saved.id
    writeContext.insert(saved)
    try writeContext.save()

    // Read back through a separate context so nothing comes from the in-memory object
    let readContext = ModelContext(container)
    let fetched = try #require(readContext.fetch(FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.id == id })).first)
    #expect(fetched.psbtBytes == original)
    #expect(fetched.psbtBase64 == original.base64EncodedString())

    // Update path: savePSBT on an existing record assigns psbtBytes again
    fetched.psbtBytes = original
    try readContext.save()
    let refetched = try #require(ModelContext(container).fetch(FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.id == id })).first)
    #expect(refetched.psbtBytes == original)

    // Load path: loadSavedPSBT must hand the same bytes to the view model
    let vm = SendViewModel(bitcoinService: MockBitcoinService())
    vm.loadSavedPSBT(refetched)
    #expect(vm.psbtBytes == original)
    #expect(try nonWitnessUtxoCount(vm.psbtBytes) == before)
  }
}

private class RoundTripBundleToken {}

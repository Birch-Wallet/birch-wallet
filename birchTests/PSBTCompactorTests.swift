@testable import birch
import BitcoinDevKit
import Foundation
import Testing
import URKit

struct PSBTCompactorTests {
  // MARK: - Helpers

  /// The 2-of-2 witness script baked into the test_psbt_nonwitness fixture
  private let fixtureWitnessScript = Data(
    hex: "5221"
      + "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
      + "21"
      + "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
      + "52ae"
  )

  /// Marker bytes unique to the embedded previous transactions (fake input txids)
  private let prevTx1Marker = Data(repeating: 0x11, count: 32)
  private let prevTx2Marker = Data(repeating: 0x22, count: 32)

  private func loadFixture(_ name: String) -> Data? {
    let bundle = Bundle(for: CompactorBundleToken.self)
    guard let path = bundle.path(forResource: name, ofType: "txt"),
          let base64 = try? String(contentsOfFile: path, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    return Data(base64Encoded: base64)
  }

  // MARK: - Compact-PSBT validity

  @Test func stripsNonWitnessUtxos() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    #expect(stripped.count < original.count)
    // Both embedded previous transactions (436 bytes) and the global xpubs
    // (~174 bytes) are gone, plus entry overhead
    #expect(original.count - stripped.count > 550)
    #expect(original.range(of: prevTx1Marker) != nil, "fixture must contain prev tx 1")
    #expect(original.range(of: prevTx2Marker) != nil, "fixture must contain prev tx 2")
    #expect(stripped.range(of: prevTx1Marker) == nil, "prev tx 1 must be stripped")
    #expect(stripped.range(of: prevTx2Marker) == nil, "prev tx 2 must be stripped")
  }

  @Test func stripsGlobalXpubs() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    // Serialized xpubs start with the mainnet version bytes 0x0488B21E
    let xpubVersionMarker = Data(hex: "0488b21e")
    #expect(original.range(of: xpubVersionMarker) != nil, "fixture must contain global xpubs")
    #expect(stripped.range(of: xpubVersionMarker) == nil, "global xpubs must be stripped")
  }

  @Test func strippedPSBTIsStillValid() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    let originalPsbt = try Psbt(psbtBase64: original.base64EncodedString())
    let strippedPsbt = try Psbt(psbtBase64: stripped.base64EncodedString())

    // Identical unsigned transaction
    let originalTxid = try originalPsbt.extractTx().computeTxid().description
    let strippedTxid = try strippedPsbt.extractTx().computeTxid().description
    #expect(originalTxid == strippedTxid)

    // Fee is still computable — proves witness_utxo survived and carries the amounts
    // (inputs 60000 + 40000, outputs 70000 + 29500 → fee 500)
    #expect(try strippedPsbt.fee() == 500)
  }

  @Test func seedSignerRequiredFieldsSurvive() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    // witness_script must remain in both input maps and the change output map
    var searchRange = stripped.startIndex ..< stripped.endIndex
    var occurrences = 0
    while let found = stripped.range(of: fixtureWitnessScript, in: searchRange) {
      occurrences += 1
      searchRange = found.upperBound ..< stripped.endIndex
    }
    #expect(occurrences >= 3, "witness_script should survive in 2 inputs + 1 output, found \(occurrences)")

    // bip32_derivation fingerprints must remain
    #expect(stripped.range(of: Data(hex: "aabbccdd")) != nil)
    #expect(stripped.range(of: Data(hex: "11223344")) != nil)
  }

  @Test func strippingIsIdempotent() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let once = PSBTCompactor.compact(original)
    let twice = PSBTCompactor.compact(once)
    #expect(once == twice)
  }

  @Test func alreadyCompactPSBTUnchanged() throws {
    // The existing unsigned fixture has witness_utxo only — nothing to strip
    let data = try #require(loadFixture("test_psbt_unsigned"))
    #expect(PSBTCompactor.compact(data) == data)
  }

  @Test func failSafeOnInvalidInput() {
    #expect(PSBTCompactor.compact(Data()) == Data())

    let garbage = Data((0 ..< 100).map { UInt8($0) })
    #expect(PSBTCompactor.compact(garbage) == garbage)

    let magicOnly = Data([0x70, 0x73, 0x62, 0x74, 0xFF])
    #expect(PSBTCompactor.compact(magicOnly) == magicOnly)
  }

  @Test func dropsOnlyExactSpecKeyShapes() {
    /// Synthetic PSBT containing look-alike entries that share a dropped entry's
    /// key TYPE but not its spec-defined key LENGTH — these must pass through:
    ///  - global: type 0x01 with a 4-byte key body (real PSBT_GLOBAL_XPUB keys are 79 bytes)
    ///  - input: type 0x00 with 2 bytes of key data (real non_witness_utxo keys are 1 byte)
    /// alongside a real non_witness_utxo (0xEE * 60 value) that must be stripped.
    func entry(key: [UInt8], value: [UInt8]) -> [UInt8] {
      [UInt8(key.count)] + key + [UInt8(value.count)] + value
    }
    // Minimal 1-in/1-out unsigned legacy tx
    let unsignedTx: [UInt8] = [2, 0, 0, 0] // version
      + [1] + [UInt8](repeating: 0xAB, count: 32) + [0, 0, 0, 0] + [0] + [0xFD, 0xFF, 0xFF, 0xFF]
      + [1] + [0x88, 0x13, 0, 0, 0, 0, 0, 0] + [0x16, 0x00, 0x14] + [UInt8](repeating: 0x99, count: 20)
      + [0, 0, 0, 0] // locktime

    var psbt: [UInt8] = [0x70, 0x73, 0x62, 0x74, 0xFF]
    psbt += entry(key: [0x00], value: unsignedTx) // global unsigned tx
    psbt += entry(key: [0x01, 0xAA, 0xBB, 0xCC, 0xDD], value: [0x11, 0x22, 0x33, 0x44]) // xpub look-alike
    psbt += [0x00] // end global map
    psbt += entry(key: [0x00], value: [UInt8](repeating: 0xEE, count: 60)) // real non_witness_utxo
    psbt += entry(key: [0x00, 0x51, 0x52], value: [0xCA, 0xFE]) // type-0x00 look-alike with key data
    psbt += entry(key: [0x01], value: [0x88, 0x13, 0, 0, 0, 0, 0, 0, 0x16, 0x00, 0x14]
      + [UInt8](repeating: 0x99, count: 20)) // witness_utxo
    psbt += [0x00] // end input map
    psbt += [0x00] // empty output map

    let original = Data(psbt)
    let compacted = PSBTCompactor.compact(original)

    // The real non_witness_utxo is gone
    #expect(compacted.range(of: Data(repeating: 0xEE, count: 60)) == nil)
    // The malformed global type-0x01 entry survives (its unique key bytes remain)
    #expect(compacted.range(of: Data([0x01, 0xAA, 0xBB, 0xCC, 0xDD])) != nil)
    // The input type-0x00 entry with key data survives (key 0x00 0x51 0x52, value 0xCA 0xFE)
    #expect(compacted.range(of: Data([0x03, 0x00, 0x51, 0x52, 0x02, 0xCA, 0xFE])) != nil)
    // Exactly the non_witness_utxo entry was removed (1B keylen + 1B key + 1B valuelen + 60B value)
    #expect(original.count - compacted.count == 63)
  }

  @Test func psbtV2PassesThroughUnchanged() {
    /// BIP-370 (PSBT v2) removes the global unsigned tx, which the compactor
    /// needs for the input count. Without it the walk aborts and the ENTIRE
    /// original PSBT is returned — no partial stripping (not even the global
    /// map), even though this v2 fixture carries a non_witness_utxo entry.
    func entry(key: [UInt8], value: [UInt8]) -> [UInt8] {
      [UInt8(key.count)] + key + [UInt8(value.count)] + value
    }
    var psbt: [UInt8] = [0x70, 0x73, 0x62, 0x74, 0xFF]
    psbt += entry(key: [0x02], value: [2, 0, 0, 0]) // PSBT_GLOBAL_TX_VERSION
    psbt += entry(key: [0x04], value: [1]) // PSBT_GLOBAL_INPUT_COUNT
    psbt += entry(key: [0x05], value: [1]) // PSBT_GLOBAL_OUTPUT_COUNT
    psbt += entry(key: [0xFB], value: [2, 0, 0, 0]) // PSBT_GLOBAL_VERSION = 2
    psbt += [0x00] // end global map
    psbt += entry(key: [0x00], value: [UInt8](repeating: 0xEE, count: 40)) // non_witness_utxo
    psbt += entry(key: [0x0E], value: [UInt8](repeating: 0xAB, count: 32)) // PSBT_IN_PREVIOUS_TXID
    psbt += [0x00] // end input map
    psbt += [0x00] // empty output map

    let v2psbt = Data(psbt)
    #expect(PSBTCompactor.compact(v2psbt) == v2psbt)
  }

  @Test func failSafeOnTruncatedPSBT() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let truncated = original.prefix(original.count / 2)
    #expect(PSBTCompactor.compact(Data(truncated)) == Data(truncated))
  }

  // MARK: - QR/UR output validity

  @Test func strippedPSBTEncodesToValidUR() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    let ur = try URService.encodePSBT(stripped)
    #expect(ur.type == "crypto-psbt")
    #expect(try URService.decodePSBT(from: ur) == stripped)
  }

  @Test func strippedPSBTMultiPartURRoundTrip() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    let ur = try URService.encodePSBT(stripped)
    let encoder = UREncoder(ur, maxFragmentLen: 160)
    #expect(!encoder.isSinglePart, "payload should span multiple animated QR frames")

    var parts: [String] = []
    for _ in 0 ..< encoder.seqLen {
      parts.append(encoder.nextPart())
    }
    let result = URService.processMultiPartURStrings(parts)
    guard case let .psbt(decoded) = result else {
      Issue.record("Expected .psbt result, got \(String(describing: result))")
      return
    }
    #expect(decoded == stripped)
  }

  @Test func compactionReducesFrameCount() throws {
    let original = try #require(loadFixture("test_psbt_nonwitness"))
    let stripped = PSBTCompactor.compact(original)

    let originalEncoder = try UREncoder(URService.encodePSBT(original), maxFragmentLen: 160)
    let strippedEncoder = try UREncoder(URService.encodePSBT(stripped), maxFragmentLen: 160)
    #expect(strippedEncoder.seqLen < originalEncoder.seqLen)
  }
}

private class CompactorBundleToken {}

private extension Data {
  init(hex: String) {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      data.append(UInt8(hex[index ..< next], radix: 16)!)
      index = next
    }
    self = data
  }
}

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

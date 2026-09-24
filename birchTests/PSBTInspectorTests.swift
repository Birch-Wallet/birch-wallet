@testable import birch
import Foundation
import Testing

struct PSBTInspectorTests {
  // MARK: - Helpers

  private func loadFixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: InspectorBundleToken.self)
    let path = try #require(bundle.path(forResource: name, ofType: "txt"))
    let base64 = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(Data(base64Encoded: base64))
  }

  private func model(_ data: Data, compact: Bool = true) throws -> PSBTInspectorModel {
    try PSBTInspectorModel.build(
      psbtBytes: data,
      compactEnabled: compact,
      cosigners: [],
      requiredSignatures: 2,
      networkName: nil
    )
  }

  private static let magic: [UInt8] = [0x70, 0x73, 0x62, 0x74, 0xFF]

  /// A 60-byte, one-input one-output unsigned transaction
  private static let minimalTx: [UInt8] =
    [0x02, 0x00, 0x00, 0x00, 0x01]
      + [UInt8](repeating: 0xAB, count: 32) + [0x00, 0x00, 0x00, 0x00, 0x00, 0xFD, 0xFF, 0xFF, 0xFF]
      + [0x01, 0x10, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
      + [0x00, 0x00, 0x00, 0x00]

  private static var txRecord: [UInt8] {
    [0x01, 0x00, UInt8(minimalTx.count)] + minimalTx
  }

  /// Real PSBTs only: test_psbt_unsigned and test_psbt_partial are hand-built and
  /// not valid BIP-174 (their global map is never closed), so they cannot be parsed
  private static let fixtures = [
    "test_psbt_2in_unsigned", "test_psbt_2in_one_sig", "test_psbt_10in_partial", "test_psbt_nonwitness",
  ]

  // MARK: - Parser

  @Test(arguments: fixtures)
  func recordsAccountForEveryByte(fixture: String) throws {
    let data = try loadFixture(fixture)
    let parsed = try PSBTParser.parse(data)
    let separators = 1 + parsed.inputCount + parsed.outputCount
    #expect(5 + parsed.records.reduce(0) { $0 + $1.length } + separators == data.count)
    #expect(parsed.unsignedTx?.inputs.count == parsed.inputCount)
    // Records are in file order with no gaps inside a map
    for (a, b) in zip(parsed.records, parsed.records.dropFirst()) where a.map == b.map {
      #expect(a.offset + a.length == b.offset)
    }
  }

  @Test func parsesMinimalPSBT() throws {
    let data = Data(Self.magic + Self.txRecord + [0x00, 0x00, 0x00])
    let parsed = try PSBTParser.parse(data)
    #expect(parsed.records.count == 1)
    #expect(parsed.unsignedTx?.outputs.first?.amount == 10000)
    #expect(parsed.unsignedTx?.inputs.first?.sequence == 0xFFFF_FFFD)

    let inspector = try model(data)
    let output = try #require(inspector.sections.first { $0.location == .output(0) })
    #expect(output.fields.isEmpty)
    #expect(output.emptyNote?.contains("10,000 sats") == true)
  }

  @Test func rejectsBadMagic() {
    var bytes = Self.magic + Self.txRecord + [0x00, 0x00, 0x00]
    bytes[0] = 0x71
    #expect(throws: PSBTParseError.self) { try PSBTParser.parse(Data(bytes)) }
  }

  @Test func rejectsTruncatedFile() throws {
    let data = try loadFixture("test_psbt_2in_one_sig")
    let error = #expect(throws: PSBTParseError.self) { try PSBTParser.parse(data.dropLast()) }
    #expect(error?.offset != nil)
  }

  @Test func rejectsDuplicateKeys() {
    let data = Data(Self.magic + Self.txRecord + Self.txRecord + [0x00, 0x00, 0x00])
    let error = #expect(throws: PSBTParseError.self) { try PSBTParser.parse(data) }
    #expect(error?.reason.contains("Duplicate") == true)
    #expect(error?.offset == 5 + Self.txRecord.count)
  }

  @Test func rejectsUnsupportedVersion() {
    let version: [UInt8] = [0x01, 0xFB, 0x04, 0x01, 0x00, 0x00, 0x00]
    let data = Data(Self.magic + Self.txRecord + version + [0x00, 0x00, 0x00])
    let error = #expect(throws: PSBTParseError.self) { try PSBTParser.parse(data) }
    #expect(error?.reason.contains("Unsupported PSBT version 1") == true)
  }

  @Test func keepsUnknownAndProprietaryRecords() throws {
    let unknown: [UInt8] = [0x01, 0x42, 0x02, 0xDE, 0xAD]
    let proprietary: [UInt8] = [0x03, 0xFC, 0x01, 0x61, 0x01, 0x00]
    let data = Data(Self.magic + Self.txRecord + [0x00] + unknown + proprietary + [0x00, 0x00])
    let inspector = try model(data)
    let input = try #require(inspector.sections.first { $0.location == .input(0) })
    #expect(input.fields.map(\.name) == ["unknown 0x42", "proprietary"])
    #expect(input.fields.allSatisfy { $0.tags.contains(.unrecognized) })
  }

  // MARK: - Model

  @Test func inQRLensMatchesCompactor() throws {
    let data = try loadFixture("test_psbt_nonwitness")
    let inspector = try model(data)
    let compacted = PSBTCompactor.compact(data)
    #expect(compacted.count < data.count)
    #expect(inspector.compactBytes == compacted.count)

    // Fields left out of the QR account for exactly the bytes the compactor removes
    let droppedBytes = inspector.fields
      .filter { !$0.tags.contains(.inQR) }
      .reduce(0) { $0 + $1.bytes }
    #expect(droppedBytes > 0)
    #expect(data.count - droppedBytes == compacted.count)
    #expect(inspector.qrPayloadBytes == compacted.count)
  }

  @Test func compactOffKeepsEverythingInQR() throws {
    let data = try loadFixture("test_psbt_nonwitness")
    let inspector = try model(data, compact: false)
    #expect(inspector.fields.allSatisfy { $0.tags.contains(.inQR) })
  }

  @Test(arguments: fixtures)
  func unsignedTxBreakdownSumsToRecord(fixture: String) throws {
    let inspector = try model(loadFixture(fixture))
    let field = try #require(inspector.fields.first { $0.section == .global && $0.keyType == 0x00 })
    let parts = try #require(field.parts)
    #expect(parts.reduce(0) { $0 + $1.bytes } == field.bytes)
  }

  @Test(arguments: fixtures)
  func repeatedRecordsCollapseIntoOneRow(fixture: String) throws {
    let data = try loadFixture(fixture)
    let inspector = try model(data)
    #expect(inspector.fields.reduce(0) { $0 + $1.count } == inspector.parsed.records.count)
    for field in inspector.fields {
      let matching = inspector.parsed.records(in: field.section).filter { $0.keyType == field.keyType }
      #expect(field.count == matching.count)
      #expect(field.bytes == matching.reduce(0) { $0 + $1.length })
      #expect(field.name.hasSuffix("×\(field.count)") == (field.count > 1))
    }
  }

  @Test(arguments: fixtures)
  func derivationBreakdownSumsToOneEntry(fixture: String) throws {
    let inspector = try model(loadFixture(fixture))
    for field in inspector.fields where field.keyType == 0x06 && field.section != .global {
      let parts = try #require(field.parts)
      #expect(parts.reduce(0) { $0 + $1.bytes } == field.records[0].length)
    }
  }

  /// Byte counts for a real 10-input, 1-output multisig PSBT, cross-checked against
  /// an independent BIP-174 decoder
  @Test func realPSBTByteCounts() throws {
    let data = try loadFixture("test_psbt_10in_partial")
    let inspector = try model(data)
    #expect(inspector.parsed.totalBytes == 13854)
    #expect(inspector.totalRecords == 160)
    #expect(inspector.framingBytes + inspector.parsed.records.reduce(0) { $0 + $1.length } == data.count)

    let bytesBySection = Dictionary(uniqueKeysWithValues: inspector.sections.map { ($0.label, $0.bytes) })
    #expect(bytesBySection["Global"] == 1377)
    #expect(bytesBySection["Output 0"] == 890)
    for i in 0 ..< 10 {
      #expect(bytesBySection["Input \(i)"] == 1157)
    }

    let input0 = try #require(inspector.sections.first { $0.location == .input(0) })
    let fieldBytes = Dictionary(uniqueKeysWithValues: input0.fields.map { ($0.keyType, $0.bytes) })
    #expect(fieldBytes == [0x01: 46, 0x02: 214, 0x03: 7, 0x05: 314, 0x06: 576])

    // One bip32_derivation entry: 1 key length + 1 type + 33 pubkey + 1 value length + 4 fingerprint + 24 path
    let derivation = try #require(input0.fields.first { $0.keyType == 0x06 })
    #expect(derivation.parts?.map(\.bytes) == [2, 1, 33, 4, 24])

    #expect(inspector.compactBytes == 12945)
    #expect(inspector.stat(for: .inQR) == "151 of 160 pairs · 12,945 B")
    #expect(try model(data, compact: false).stat(for: .inQR) == "160 of 160 pairs · 13,854 B")
  }

  /// Only the fields a P2WSH signer truly cannot sign without are "Required to sign",
  /// and only output proof fields are "Verifies change"
  @Test func signingRoleTagsAreAccurate() throws {
    let inspector = try model(loadFixture("test_psbt_10in_partial"))
    let byLocation = Dictionary(grouping: inspector.fields, by: \.section)

    let input0 = try #require(byLocation[.input(0)])
    let required = Set(input0.filter { $0.tags.contains(.requiredToSign) }.map(\.keyType))
    #expect(required == [0x01, 0x05, 0x06]) // witness_utxo, witness_script, bip32_derivation
    #expect(input0.allSatisfy { !$0.tags.contains(.verifiesChange) })

    let output0 = try #require(byLocation[.output(0)])
    let verifies = Set(output0.filter { $0.tags.contains(.verifiesChange) }.map(\.keyType))
    #expect(verifies == [0x01, 0x02]) // witness_script, bip32_derivation
    #expect(output0.allSatisfy { !$0.tags.contains(.requiredToSign) })

    let global = try #require(byLocation[.global])
    #expect(global.allSatisfy { $0.tags.isDisjoint(with: [.requiredToSign, .verifiesChange]) })

    // Optional for a segwit signer: neither is required
    let nonWitness = try loadFixture("test_psbt_nonwitness")
    let optional = try model(nonWitness).fields.filter { [0x00, 0x03].contains($0.keyType) && $0.section != .global }
    #expect(!optional.isEmpty)
    #expect(optional.allSatisfy { !$0.tags.contains(.requiredToSign) })
  }

  @Test func signingLensReflectsSignatures() throws {
    let unsigned = try model(loadFixture("test_psbt_2in_unsigned"))
    #expect(!unsigned.parsed.records.contains { $0.keyType == 0x02 && $0.map != .global })
    #expect(unsigned.note(for: .signing).hasPrefix("No signatures yet"))

    let partial = try model(loadFixture("test_psbt_2in_one_sig"))
    let sigRecords = partial.parsed.records.filter {
      if case .input = $0.map {
        return $0.keyType == 0x02
      }
      return false
    }
    #expect(!sigRecords.isEmpty)
    let sigRows = partial.fields.filter { $0.keyType == 0x02 && $0.tags.contains(.signing) }
    #expect(sigRows.reduce(0) { $0 + $1.count } == sigRecords.count)
    #expect(partial.note(for: .signing).hasPrefix("Signature material"))
  }

  @Test(arguments: fixtures)
  func realSignaturesAllCount(fixture: String) throws {
    let parsed = try PSBTParser.parse(loadFixture(fixture))
    for i in 0 ..< parsed.inputCount {
      let (counted, foreign) = parsed.partialSignatures(input: i)
      #expect(foreign.isEmpty)
      #expect(counted.count == parsed.records(in: .input(i)).count(where: { $0.keyType == 0x02 }))
    }
  }

  @Test func witnessScriptPubkeysAreExtracted() throws {
    let parsed = try PSBTParser.parse(loadFixture("test_psbt_10in_partial"))
    let script = try #require(parsed.records(in: .input(0)).first { $0.keyType == 0x05 })
    let summary = try #require(PSBTParser.multisigSummary(script.value))
    let keys = PSBTParser.compressedPubkeys(in: script.value)
    #expect(keys.count == summary.n)
    // Every bip32_derivation pubkey on the input is one of the script's keys
    let derivationKeys = parsed.records(in: .input(0)).filter { $0.keyType == 0x06 }.map(\.keyData)
    #expect(Set(derivationKeys) == Set(keys))
  }

  /// A signature keyed by a pubkey outside the input's witness script must not count
  /// toward the threshold, even though it is a well-formed partial_sig record
  @Test func foreignSignatureDoesNotCount() throws {
    var bytes = try [UInt8](loadFixture("test_psbt_2in_one_sig"))
    let original = try PSBTParser.parse(Data(bytes))
    let sig = try #require(original.records.first { $0.keyType == 0x02 && $0.map != .global })
    guard case let .input(inputIndex) = sig.map else {
      Issue.record("partial_sig outside an input map")
      return
    }
    let before = original.partialSignatures(input: inputIndex).counted.count

    // Flip the last byte of the pubkey in the record's key: same length, foreign key
    let pubkeyEnd = sig.offset + sig.keyLengthPrefix + 1 + sig.keyData.count
    bytes[pubkeyEnd - 1] ^= 0x01
    let data = Data(bytes)
    let tampered = try PSBTParser.parse(data)
    let (counted, foreign) = tampered.partialSignatures(input: inputIndex)
    #expect(counted.count == before - 1)
    #expect(foreign.count == 1)

    let inspector = try model(data)
    let field = try #require(inspector.fields.first { $0.section == .input(inputIndex) && $0.keyType == 0x02 })
    #expect(field.definition.contains("cannot count"))
    #expect(field.parts?.contains { $0.label.hasSuffix("not in script") } == true)
  }

  // MARK: - Layout

  /// The regular-width layout splits sections into two reading-order columns of
  /// near-equal expanded height, instead of a fixed Global + Input 0 left column
  @Test func regularColumnsBalance() throws {
    let tenInputs = try model(loadFixture("test_psbt_10in_partial"))
    #expect(tenInputs.sections.count == 12)
    #expect(PSBTInspectorView.columnSplit(tenInputs.sections, scale: 0.14, maxRowHeight: 360) == 6)

    let twoInputs = try model(loadFixture("test_psbt_2in_unsigned"))
    #expect(PSBTInspectorView.columnSplit(twoInputs.sections, scale: 0.14, maxRowHeight: 360) == 2)
  }

  @Test func witnessUtxoCopyOnlyMentionsCompactWhenItDrops() throws {
    let data = try loadFixture("test_psbt_nonwitness")
    let claim = "compact QR drops non_witness_utxo"
    func witnessUtxo(_ psbt: Data, compact: Bool) throws -> PSBTField {
      try #require(model(psbt, compact: compact).fields.first { $0.keyType == 0x01 && $0.section != .global })
    }
    #expect(try witnessUtxo(data, compact: true).extended.contains(claim))
    // Compact PSBT off: the QR carries non_witness_utxo
    #expect(try !witnessUtxo(data, compact: false).extended.contains(claim))
    // Compact on, but nothing left to strip
    #expect(try !witnessUtxo(PSBTCompactor.compact(data), compact: true).extended.contains(claim))
  }
}

private class InspectorBundleToken {}

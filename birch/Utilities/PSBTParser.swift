import CryptoKit
import Foundation

/// Which BIP-174 map a record belongs to.
enum PSBTMapLocation: Hashable {
  case global
  case input(Int)
  case output(Int)

  var id: String {
    switch self {
    case .global: "g"
    case let .input(i): "i\(i)"
    case let .output(i): "o\(i)"
    }
  }
}

/// One serialized key-value pair, with its exact position and size in the file.
struct PSBTRecord: Equatable {
  let map: PSBTMapLocation
  /// Byte offset of the record's key-length prefix
  let offset: Int
  /// Total serialized size: key length prefix + key + value length prefix + value
  let length: Int
  /// Size of the key-length compact size prefix
  let keyLengthPrefix: Int
  /// Size of the value-length compact size prefix
  let valueLengthPrefix: Int
  let keyType: UInt64
  let keyData: Data
  let value: Data

  /// Identity of a record within its map: BIP-174 forbids duplicate keys, so map
  /// plus full key is unique.
  struct Identity: Hashable {
    let map: PSBTMapLocation
    let keyType: UInt64
    let keyData: Data
  }

  var identity: Identity {
    Identity(map: map, keyType: keyType, keyData: keyData)
  }
}

/// A pre-segwit serialized transaction, broken down just far enough to size its parts.
struct PSBTUnsignedTx: Equatable {
  struct Input: Equatable {
    let txid: Data
    let vout: UInt32
    let sequence: UInt32
    /// Serialized size: txid + vout + scriptSig (with prefix) + sequence
    let length: Int
  }

  struct Output: Equatable {
    let amount: UInt64
    let script: Data
    /// Serialized size: amount + script (with prefix)
    let length: Int
  }

  let version: Int32
  let inputs: [Input]
  let outputs: [Output]
  let lockTime: UInt32
  let inputCountLength: Int
  let outputCountLength: Int
}

struct ParsedPSBT: Sendable {
  let totalBytes: Int
  /// PSBT_GLOBAL_VERSION, 0 when absent
  let version: UInt32
  let records: [PSBTRecord]
  let inputCount: Int
  let outputCount: Int
  /// Present for version 0 PSBTs
  let unsignedTx: PSBTUnsignedTx?

  func records(in map: PSBTMapLocation) -> [PSBTRecord] {
    records.filter { $0.map == map }
  }

  /// Splits an input's partial signatures into those that can count toward its
  /// threshold and those that cannot. A signature counts only when its pubkey is one
  /// of the keys in the input's witness script, and that script hashes to the P2WSH
  /// scriptPubKey in witness_utxo. With no witness script there is nothing to check
  /// against, so every signature counts.
  func partialSignatures(input index: Int) -> (counted: [PSBTRecord], foreign: [PSBTRecord]) {
    let inputRecords = records(in: .input(index))
    let signatures = inputRecords.filter { $0.keyType == 0x02 }
    guard let witnessScript = inputRecords.first(where: { $0.keyType == 0x05 && $0.keyData.isEmpty })?.value else {
      return (signatures, [])
    }
    if let spent = inputRecords.first(where: { $0.keyType == 0x01 && $0.keyData.isEmpty })
      .flatMap({ PSBTParser.witnessUtxoScript($0.value) }),
      spent.count == 34, spent[spent.startIndex] == 0x00, spent[spent.startIndex + 1] == 0x20,
      Data(SHA256.hash(data: witnessScript)) != spent.suffix(32)
    {
      return ([], signatures) // the script does not govern this input
    }
    let keys = Set(PSBTParser.compressedPubkeys(in: witnessScript))
    return (signatures.filter { keys.contains($0.keyData) }, signatures.filter { !keys.contains($0.keyData) })
  }
}

struct PSBTParseError: Error, Equatable, LocalizedError, Sendable {
  let reason: String
  let offset: Int?

  var errorDescription: String? {
    reason
  }
}

/// A byte-level walk over a serialized BIP-174 / BIP-370 PSBT. BDK gives the
/// semantics of a PSBT but no sizes or offsets; this gives exactly those, and
/// passes unknown and proprietary records through as-is.
enum PSBTParser {
  private static let magic: [UInt8] = [0x70, 0x73, 0x62, 0x74, 0xFF] // "psbt" + 0xFF

  static func parse(_ data: Data) throws -> ParsedPSBT {
    let bytes = [UInt8](data)
    guard bytes.count >= magic.count, Array(bytes.prefix(magic.count)) == magic else {
      throw PSBTParseError(reason: "Not a PSBT: the file does not start with the psbt magic bytes.", offset: 0)
    }
    var offset = magic.count
    var records: [PSBTRecord] = []

    let global = try readMap(bytes, &offset, map: .global)
    records += global

    var version: UInt32 = 0
    if let versionRecord = global.first(where: { $0.keyType == 0xFB && $0.keyData.isEmpty }) {
      guard versionRecord.value.count == 4 else {
        throw PSBTParseError(reason: "PSBT_GLOBAL_VERSION must be 4 bytes.", offset: versionRecord.offset)
      }
      version = readUInt32([UInt8](versionRecord.value), 0)
    }

    let inputCount: Int
    let outputCount: Int
    var unsignedTx: PSBTUnsignedTx?

    switch version {
    case 0:
      guard let txRecord = global.first(where: { $0.keyType == 0x00 && $0.keyData.isEmpty }) else {
        throw PSBTParseError(reason: "Missing PSBT_GLOBAL_UNSIGNED_TX, which a version 0 PSBT requires.", offset: nil)
      }
      guard let tx = parseUnsignedTx(txRecord.value) else {
        throw PSBTParseError(reason: "The unsigned transaction could not be decoded.", offset: txRecord.offset)
      }
      unsignedTx = tx
      inputCount = tx.inputs.count
      outputCount = tx.outputs.count
    case 2:
      guard let inRecord = global.first(where: { $0.keyType == 0x04 && $0.keyData.isEmpty }),
            let outRecord = global.first(where: { $0.keyType == 0x05 && $0.keyData.isEmpty })
      else {
        throw PSBTParseError(reason: "A version 2 PSBT must carry PSBT_GLOBAL_INPUT_COUNT and PSBT_GLOBAL_OUTPUT_COUNT.", offset: nil)
      }
      var inOffset = 0, outOffset = 0
      guard let ins = readCompactSize([UInt8](inRecord.value), &inOffset),
            let outs = readCompactSize([UInt8](outRecord.value), &outOffset),
            let insInt = Int(exactly: ins), let outsInt = Int(exactly: outs),
            insInt <= bytes.count, outsInt <= bytes.count
      else {
        throw PSBTParseError(reason: "The input or output count is malformed.", offset: inRecord.offset)
      }
      inputCount = insInt
      outputCount = outsInt
    default:
      throw PSBTParseError(reason: "Unsupported PSBT version \(version). BIP-174 requires aborting on a version the parser does not recognise.", offset: nil)
    }

    for i in 0 ..< inputCount {
      records += try readMap(bytes, &offset, map: .input(i))
    }
    for i in 0 ..< outputCount {
      records += try readMap(bytes, &offset, map: .output(i))
    }

    guard offset == bytes.count else {
      throw PSBTParseError(
        reason: "Found \(bytes.count - offset) unexpected bytes after the last output map. The map count may not match the transaction.",
        offset: offset
      )
    }

    return ParsedPSBT(
      totalBytes: bytes.count,
      version: version,
      records: records,
      inputCount: inputCount,
      outputCount: outputCount,
      unsignedTx: unsignedTx
    )
  }

  /// Reads one key-value map through its 0x00 separator.
  private static func readMap(_ bytes: [UInt8], _ offset: inout Int, map: PSBTMapLocation) throws -> [PSBTRecord] {
    var records: [PSBTRecord] = []
    var seenKeys = Set<Data>()
    while true {
      guard offset < bytes.count else {
        throw PSBTParseError(reason: "The file ends before the \(mapName(map)) map is closed.", offset: offset)
      }
      if bytes[offset] == 0x00 { // map separator
        offset += 1
        return records
      }
      let start = offset
      guard let keyLen64 = readCompactSize(bytes, &offset), let keyLen = Int(exactly: keyLen64) else {
        throw PSBTParseError(reason: "Malformed key length in the \(mapName(map)) map.", offset: start)
      }
      let keyLengthPrefix = offset - start
      let keyStart = offset
      guard keyLen <= bytes.count - keyStart else {
        throw PSBTParseError(reason: "A key in the \(mapName(map)) map runs past the end of the file.", offset: start)
      }
      var keyCursor = keyStart
      guard let keyType = readCompactSize(bytes, &keyCursor), keyCursor <= keyStart + keyLen else {
        throw PSBTParseError(reason: "Malformed key type in the \(mapName(map)) map.", offset: start)
      }
      let keyBytes = Data(bytes[keyStart ..< keyStart + keyLen])
      let keyData = Data(bytes[keyCursor ..< keyStart + keyLen])
      offset = keyStart + keyLen

      let valueLenStart = offset
      guard let valueLen64 = readCompactSize(bytes, &offset), let valueLen = Int(exactly: valueLen64) else {
        throw PSBTParseError(reason: "Malformed value length in the \(mapName(map)) map.", offset: valueLenStart)
      }
      let valueLengthPrefix = offset - valueLenStart
      guard valueLen <= bytes.count - offset else {
        throw PSBTParseError(reason: "A value in the \(mapName(map)) map runs past the end of the file.", offset: start)
      }
      let value = Data(bytes[offset ..< offset + valueLen])
      offset += valueLen

      guard seenKeys.insert(keyBytes).inserted else {
        throw PSBTParseError(
          reason: "Duplicate key \(String(format: "0x%02llX", keyType)) in the \(mapName(map)) map. BIP-174 forbids duplicate keys.",
          offset: start
        )
      }

      records.append(PSBTRecord(
        map: map,
        offset: start,
        length: offset - start,
        keyLengthPrefix: keyLengthPrefix,
        valueLengthPrefix: valueLengthPrefix,
        keyType: keyType,
        keyData: keyData,
        value: value
      ))
    }
  }

  private static func mapName(_ map: PSBTMapLocation) -> String {
    switch map {
    case .global: "global"
    case let .input(i): "input \(i)"
    case let .output(i): "output \(i)"
    }
  }

  // MARK: - Unsigned transaction

  static func parseUnsignedTx(_ data: Data) -> PSBTUnsignedTx? {
    let bytes = [UInt8](data)
    var offset = 0
    guard bytes.count >= 10 else { return nil }
    let version = Int32(bitPattern: readUInt32(bytes, 0))
    offset = 4
    // BIP-174 requires the pre-segwit serialization; a 0x00 input count here would
    // be the segwit marker
    let countStart = offset
    guard let inCount64 = readCompactSize(bytes, &offset), inCount64 > 0,
          let inCount = Int(exactly: inCount64), inCount <= bytes.count / 41
    else { return nil }
    let inputCountLength = offset - countStart

    var inputs: [PSBTUnsignedTx.Input] = []
    for _ in 0 ..< inCount {
      let start = offset
      guard bytes.count - offset >= 36 else { return nil }
      let txid = Data(bytes[offset ..< offset + 32])
      let vout = readUInt32(bytes, offset + 32)
      offset += 36
      guard let scriptLen64 = readCompactSize(bytes, &offset), let scriptLen = Int(exactly: scriptLen64),
            scriptLen <= bytes.count - offset
      else { return nil }
      offset += scriptLen
      guard bytes.count - offset >= 4 else { return nil }
      let sequence = readUInt32(bytes, offset)
      offset += 4
      inputs.append(.init(txid: txid, vout: vout, sequence: sequence, length: offset - start))
    }

    let outCountStart = offset
    guard let outCount64 = readCompactSize(bytes, &offset), let outCount = Int(exactly: outCount64),
          outCount <= bytes.count / 9
    else { return nil }
    let outputCountLength = offset - outCountStart

    var outputs: [PSBTUnsignedTx.Output] = []
    for _ in 0 ..< outCount {
      let start = offset
      guard bytes.count - offset >= 8 else { return nil }
      let amount = readUInt64(bytes, offset)
      offset += 8
      guard let scriptLen64 = readCompactSize(bytes, &offset), let scriptLen = Int(exactly: scriptLen64),
            scriptLen <= bytes.count - offset
      else { return nil }
      let script = Data(bytes[offset ..< offset + scriptLen])
      offset += scriptLen
      outputs.append(.init(amount: amount, script: script, length: offset - start))
    }

    guard bytes.count - offset == 4 else { return nil }
    let lockTime = readUInt32(bytes, offset)

    return PSBTUnsignedTx(
      version: version,
      inputs: inputs,
      outputs: outputs,
      lockTime: lockTime,
      inputCountLength: inputCountLength,
      outputCountLength: outputCountLength
    )
  }

  // MARK: - Field helpers

  /// Decodes a BIP32 derivation value: 4-byte master fingerprint plus little-endian
  /// uint32 path levels.
  static func derivation(from value: Data) -> (fingerprint: String, path: String, levels: Int)? {
    let bytes = [UInt8](value)
    guard bytes.count >= 4, bytes.count % 4 == 0 else { return nil }
    let fingerprint = bytes[0 ..< 4].map { String(format: "%02x", $0) }.joined()
    var components = ["m"]
    var offset = 4
    while offset < bytes.count {
      let index = readUInt32(bytes, offset)
      components.append(index >= 0x8000_0000 ? "\(index - 0x8000_0000)h" : "\(index)")
      offset += 4
    }
    return (fingerprint, components.joined(separator: "/"), (bytes.count - 4) / 4)
  }

  /// The m and n of a bare `OP_m <pubkeys> OP_n OP_CHECKMULTISIG` script.
  static func multisigSummary(_ script: Data) -> (m: Int, n: Int)? {
    let bytes = [UInt8](script)
    guard bytes.count >= 37, bytes.last == 0xAE,
          (0x51 ... 0x60).contains(bytes[0]),
          (0x51 ... 0x60).contains(bytes[bytes.count - 2])
    else { return nil }
    return (Int(bytes[0]) - 0x50, Int(bytes[bytes.count - 2]) - 0x50)
  }

  /// The compressed pubkeys a script pushes, in order: every 33-byte push that starts
  /// 0x02 or 0x03. Walks opcodes so bytes inside another push are never misread as keys.
  static func compressedPubkeys(in script: Data) -> [Data] {
    let bytes = [UInt8](script)
    var keys: [Data] = []
    var offset = 0
    while offset < bytes.count {
      let opcode = bytes[offset]
      offset += 1
      var pushLength = 0
      switch opcode {
      case 0x01 ... 0x4B:
        pushLength = Int(opcode)
      case 0x4C where offset + 1 <= bytes.count: // OP_PUSHDATA1
        pushLength = Int(bytes[offset])
        offset += 1
      case 0x4D where offset + 2 <= bytes.count: // OP_PUSHDATA2
        pushLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        offset += 2
      case 0x4E where offset + 4 <= bytes.count: // OP_PUSHDATA4
        pushLength = Int(readUInt32(bytes, offset))
        offset += 4
      default:
        continue
      }
      guard pushLength <= bytes.count - offset else { break }
      if pushLength == 33, bytes[offset] == 0x02 || bytes[offset] == 0x03 {
        keys.append(Data(bytes[offset ..< offset + 33]))
      }
      offset += pushLength
    }
    return keys
  }

  /// The scriptPubKey inside a witness_utxo value: 8-byte amount, compact size length, script.
  static func witnessUtxoScript(_ value: Data) -> Data? {
    let bytes = [UInt8](value)
    var offset = 8
    guard bytes.count > offset, let length64 = readCompactSize(bytes, &offset),
          let length = Int(exactly: length64), length == bytes.count - offset
    else { return nil }
    return Data(bytes[offset...])
  }

  static func sighashName(_ flag: UInt32) -> String {
    switch flag {
    case 0x00: "SIGHASH_DEFAULT"
    case 0x01: "SIGHASH_ALL"
    case 0x02: "SIGHASH_NONE"
    case 0x03: "SIGHASH_SINGLE"
    case 0x81: "SIGHASH_ALL|ANYONECANPAY"
    case 0x82: "SIGHASH_NONE|ANYONECANPAY"
    case 0x83: "SIGHASH_SINGLE|ANYONECANPAY"
    default: "non-standard sighash"
    }
  }

  static func compactSizeLength(_ value: Int) -> Int {
    switch value {
    case 0 ..< 0xFD: 1
    case 0xFD ... 0xFFFF: 3
    case 0x10000 ... 0xFFFF_FFFF: 5
    default: 9
    }
  }

  // MARK: - Byte readers

  static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }

  static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    UInt64(readUInt32(bytes, offset)) | UInt64(readUInt32(bytes, offset + 4)) << 32
  }

  /// Bitcoin compact-size varint. Advances `offset` past the varint.
  private static func readCompactSize(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
    guard offset < bytes.count else { return nil }
    let first = bytes[offset]
    offset += 1
    switch first {
    case 0 ..< 0xFD:
      return UInt64(first)
    case 0xFD:
      guard bytes.count - offset >= 2 else { return nil }
      defer { offset += 2 }
      return UInt64(bytes[offset]) | UInt64(bytes[offset + 1]) << 8
    case 0xFE:
      guard bytes.count - offset >= 4 else { return nil }
      defer { offset += 4 }
      return UInt64(readUInt32(bytes, offset))
    default:
      guard bytes.count - offset >= 8 else { return nil }
      defer { offset += 8 }
      return readUInt64(bytes, offset)
    }
  }
}

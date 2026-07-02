import Foundation

/// Compacts a serialized BIP-174 PSBT for QR display by removing per-input
/// `non_witness_utxo` entries (the full previous transactions) and the global
/// xpub map. Segwit signers like SeedSigner and Krux only need `witness_utxo`
/// plus per-input derivations, and both verify change against their onboard
/// wallet descriptor rather than PSBT xpubs, so this can cut the animated QR
/// payload dramatically. The wallet's own copy of the PSBT is never modified —
/// this is a display-time transform only.
enum PSBTCompactor {
  private static let magic: [UInt8] = [0x70, 0x73, 0x62, 0x74, 0xFF] // "psbt" + 0xFF
  private static let psbtInNonWitnessUtxo: UInt8 = 0x00
  private static let psbtGlobalUnsignedTx: UInt8 = 0x00
  private static let psbtGlobalXpub: UInt8 = 0x01

  /// Returns the PSBT with all input `non_witness_utxo` entries and global
  /// xpubs removed. On any parse failure the original data is returned unchanged.
  static func compact(_ psbt: Data) -> Data {
    guard psbt.count > magic.count, Array(psbt.prefix(magic.count)) == magic else {
      return psbt
    }
    let bytes = [UInt8](psbt)
    var offset = magic.count
    var output = [UInt8](bytes[0 ..< offset])

    // Global map: drop xpub entries, and count inputs from the unsigned tx
    guard let unsignedTx = copyMap(bytes, &offset, into: &output, dropKeyType: psbtGlobalXpub),
          let inputCount = inputCount(inUnsignedTx: unsignedTx)
    else {
      return psbt
    }

    // Input maps: drop non_witness_utxo entries
    for _ in 0 ..< inputCount {
      guard offset < bytes.count,
            copyMap(bytes, &offset, into: &output, dropKeyType: psbtInNonWitnessUtxo) != nil
      else {
        return psbt
      }
    }

    // Output maps and anything after: copy verbatim
    output.append(contentsOf: bytes[offset...])

    return output.count < bytes.count ? Data(output) : psbt
  }

  /// Walks one key-value map (ending at its 0x00 separator), appending kept
  /// entries to `output`. Entries whose first key byte equals `dropKeyType`
  /// are skipped. Returns the value of the key-type-0x00 entry seen (used to
  /// grab the global unsigned tx), or Data() if none; nil on parse failure.
  private static func copyMap(
    _ bytes: [UInt8], _ offset: inout Int, into output: inout [UInt8], dropKeyType: UInt8?
  ) -> Data? {
    var keyTypeZeroValue = Data()
    while true {
      guard offset < bytes.count else { return nil }
      if bytes[offset] == 0x00 { // map separator
        output.append(0x00)
        offset += 1
        return keyTypeZeroValue
      }
      let entryStart = offset
      guard let keyLen = readCompactSize(bytes, &offset),
            offset + keyLen <= bytes.count else { return nil }
      let keyType = bytes[offset]
      offset += keyLen
      guard let valueLen = readCompactSize(bytes, &offset),
            offset + valueLen <= bytes.count else { return nil }
      let valueRange = offset ..< (offset + valueLen)
      offset += valueLen

      if keyType == psbtGlobalUnsignedTx, keyLen == 1 {
        keyTypeZeroValue = Data(bytes[valueRange])
      }
      // Match on key type alone: non_witness_utxo keys are 1 byte, global
      // xpub keys are 1 + 78 bytes (the serialized xpub is key data)
      if let dropKeyType, keyType == dropKeyType {
        continue // skip this entry
      }
      output.append(contentsOf: bytes[entryStart ..< valueRange.upperBound])
    }
  }

  /// Parses just far enough into an unsigned transaction to read its input count.
  private static func inputCount(inUnsignedTx tx: Data) -> Int? {
    let bytes = [UInt8](tx)
    var offset = 4 // skip version
    guard bytes.count > offset else { return nil }
    // Unsigned PSBT txs must not have the segwit marker, but tolerate it
    if bytes.count > offset + 1, bytes[offset] == 0x00, bytes[offset + 1] == 0x01 {
      offset += 2
    }
    return readCompactSize(bytes, &offset)
  }

  /// Bitcoin compact-size varint. Advances `offset` past the varint.
  private static func readCompactSize(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
    guard offset < bytes.count else { return nil }
    let first = bytes[offset]
    offset += 1
    switch first {
    case 0 ..< 0xFD:
      return Int(first)
    case 0xFD:
      guard offset + 2 <= bytes.count else { return nil }
      defer { offset += 2 }
      return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    case 0xFE:
      guard offset + 4 <= bytes.count else { return nil }
      defer { offset += 4 }
      return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    default:
      return nil // 0xFF (8-byte) lengths are not plausible in a PSBT
    }
  }
}

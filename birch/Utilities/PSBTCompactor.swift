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
  private static let psbtGlobalUnsignedTx: UInt8 = 0x00

  /// A map entry to remove, identified by its exact spec-defined key shape.
  /// Matching on both type and full key length ensures we only ever drop
  /// entries we positively recognize; anything else passes through.
  private struct DropKey {
    let keyType: UInt8
    let keyLen: Int

    /// PSBT_IN_NON_WITNESS_UTXO: key is the 1-byte type alone
    static let inNonWitnessUtxo = DropKey(keyType: 0x00, keyLen: 1)
    /// PSBT_GLOBAL_XPUB: key is the type byte + 78-byte serialized xpub
    static let globalXpub = DropKey(keyType: 0x01, keyLen: 79)
  }

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
    guard let unsignedTx = copyMap(bytes, &offset, into: &output, drop: .globalXpub),
          let inputCount = inputCount(inUnsignedTx: unsignedTx)
    else {
      return psbt
    }

    // Input maps: drop non_witness_utxo entries
    for _ in 0 ..< inputCount {
      guard offset < bytes.count,
            copyMap(bytes, &offset, into: &output, drop: .inNonWitnessUtxo) != nil
      else {
        return psbt
      }
    }

    // Output maps and anything after: copy verbatim
    output.append(contentsOf: bytes[offset...])

    return output.count < bytes.count ? Data(output) : psbt
  }

  /// Walks one key-value map (ending at its 0x00 separator), appending kept
  /// entries to `output`. Entries matching `drop` exactly (type and key length)
  /// are skipped. Returns the value of the key-type-0x00 entry seen (used to
  /// grab the global unsigned tx), or Data() if none; nil on parse failure.
  private static func copyMap(
    _ bytes: [UInt8], _ offset: inout Int, into output: inout [UInt8], drop: DropKey?
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
      // Note: key types are compact-size varints per BIP-174; reading one byte
      // is correct only for types < 0xFD, which covers everything matched here
      let keyType = bytes[offset]
      offset += keyLen
      guard let valueLen = readCompactSize(bytes, &offset),
            offset + valueLen <= bytes.count else { return nil }
      let valueRange = offset ..< (offset + valueLen)
      offset += valueLen

      if keyType == psbtGlobalUnsignedTx, keyLen == 1 {
        keyTypeZeroValue = Data(bytes[valueRange])
      }
      if let drop, keyType == drop.keyType, keyLen == drop.keyLen {
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

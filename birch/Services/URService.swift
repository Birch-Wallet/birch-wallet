import CommonCrypto
import Foundation
import URKit

/// Result types from UR QR scanning (app-level, distinct from URUI's URScanResult)
enum AppURResult {
  case psbt(Data)
  case hdKey(xpub: String, fingerprint: String, derivationPath: String)
  case descriptor(String)
  case rawBytes(Data)
  case unknown(String)

  var expectedType: ScanExpectedType? {
    switch self {
    case .psbt: .psbt
    case .hdKey: .hdKey
    case .descriptor: .descriptor
    case .rawBytes: .rawBytes
    case .unknown: nil
    }
  }

  var displayName: String {
    switch self {
    case .psbt: "a PSBT"
    case .hdKey: "a cosigner key"
    case .descriptor: "a descriptor"
    case .rawBytes: "raw data"
    case .unknown: "an unrecognized QR code"
    }
  }
}

/// Declares what type of QR result a scanner caller expects.
enum ScanExpectedType: Hashable {
  case psbt
  case hdKey
  case descriptor
  case rawBytes

  var displayName: String {
    switch self {
    case .psbt: "PSBT"
    case .hdKey: "cosigner key"
    case .descriptor: "descriptor"
    case .rawBytes: "UR-encoded data"
    }
  }
}

enum URService {
  private static let logger = AppLog(.qr)

  // MARK: - PSBT ↔ UR

  /// Encode PSBT bytes as a UR (crypto-psbt)
  static func encodePSBT(_ psbtData: Data) throws -> UR {
    let cbor = CBOR.bytes(psbtData)
    logger.debug("Encoding \(psbtData.count)-byte PSBT as crypto-psbt UR")
    return try UR(type: "crypto-psbt", cbor: cbor)
  }

  /// Decode a crypto-psbt UR back to PSBT bytes
  static func decodePSBT(from ur: UR) throws -> Data {
    guard ur.type == "crypto-psbt" else {
      throw AppError.urDecodingFailed("Expected crypto-psbt, got \(ur.type)")
    }

    guard case let .bytes(data) = ur.cbor else {
      throw AppError.urDecodingFailed("Invalid CBOR structure for crypto-psbt")
    }

    return data
  }

  // MARK: - HD Key (crypto-hdkey)

  /// Parse a crypto-hdkey UR to extract xpub, fingerprint, and derivation path
  static func parseHDKey(from ur: UR) throws -> (xpub: String, fingerprint: String, derivationPath: String) {
    guard ur.type == "crypto-hdkey" else {
      throw AppError.urDecodingFailed("Expected crypto-hdkey, got \(ur.type)")
    }

    guard case let .map(map) = ur.cbor else {
      throw AppError.urDecodingFailed("Invalid CBOR structure for crypto-hdkey")
    }

    return extractHDKeyFields(from: map)
  }

  // MARK: - Crypto Account (crypto-account)

  /// Parse a crypto-account UR to extract xpub, fingerprint, and derivation path.
  /// crypto-account structure: { 1: master-fingerprint (uint32), 2: [output-descriptors] }
  /// Each output descriptor is wrapped in CBOR tags (script type) around a crypto-hdkey map.
  static func parseCryptoAccount(from ur: UR) throws -> (xpub: String, fingerprint: String, derivationPath: String) {
    guard ur.type == "crypto-account" else {
      throw AppError.urDecodingFailed("Expected crypto-account, got \(ur.type)")
    }

    guard case let .map(accountMap) = ur.cbor else {
      throw AppError.urDecodingFailed("Invalid CBOR structure for crypto-account")
    }

    var masterFingerprint = ""
    var descriptorsCBOR: CBOR?

    for (mapKey, mapValue) in accountMap {
      guard case let .unsigned(key) = mapKey else { continue }
      switch key {
      case 1: // master-fingerprint
        if case let .unsigned(fp) = mapValue {
          masterFingerprint = String(format: "%08x", fp)
        }
      case 2: // output-descriptors array
        descriptorsCBOR = mapValue
      default:
        break
      }
    }

    guard case let .array(descriptors) = descriptorsCBOR else {
      throw AppError.urDecodingFailed("No output descriptors found in crypto-account")
    }

    // Search through output descriptors for HD keys.
    // Each descriptor is nested CBOR tags (script expressions) wrapping a crypto-hdkey map.
    // We prefer the key whose derivation path contains /2' (BIP48 P2WSH script type).
    var bestResult: (xpub: String, fingerprint: String, derivationPath: String)?

    for descriptor in descriptors {
      guard let hdKeyMapCBOR = unwrapTagsToMap(descriptor) else { continue }
      guard case let .map(hdKeyMap) = hdKeyMapCBOR else { continue }

      var result = extractHDKeyFields(from: hdKeyMap)

      // Use master fingerprint from account level if the key doesn't have one
      if result.fingerprint.isEmpty, !masterFingerprint.isEmpty {
        result.fingerprint = masterFingerprint
      }

      guard !result.xpub.isEmpty else { continue }

      // Prefer the P2WSH multisig key (derivation ends with /2')
      if result.derivationPath.hasSuffix("/2'") {
        return result
      }

      // Keep the first valid result as fallback
      if bestResult == nil {
        bestResult = result
      }
    }

    if let result = bestResult {
      return result
    }

    throw AppError.urDecodingFailed("No HD key found in crypto-account descriptors")
  }

  /// Recursively unwrap CBOR tags to find the inner map (the HD key data)
  private static func unwrapTagsToMap(_ cbor: CBOR) -> CBOR? {
    switch cbor {
    case let .tagged(_, inner):
      unwrapTagsToMap(inner)
    case .map:
      cbor
    default:
      nil
    }
  }

  /// Extract xpub, fingerprint, and derivation path from an HD key CBOR map.
  /// Shared between parseHDKey and parseCryptoAccount.
  private static func extractHDKeyFields(from map: some Sequence<(CBOR, CBOR)>) -> (xpub: String, fingerprint: String, derivationPath: String) {
    var keyData = Data()
    var chainCode = Data()
    var fingerprint = ""
    var derivationPath = ""
    var depth: UInt8 = 0
    var parentFP: UInt32 = 0
    var pathComponents: [CBOR] = []

    for (mapKey, mapValue) in map {
      guard case let .unsigned(key) = mapKey else { continue }

      switch key {
      case 3: // key-data
        if case let .bytes(bytes) = mapValue {
          keyData = bytes
        }
      case 4: // chain-code
        if case let .bytes(bytes) = mapValue {
          chainCode = bytes
        }
      case 6: // origin (crypto-keypath)
        let pathCBOR: CBOR = if case let .tagged(_, inner) = mapValue {
          inner
        } else {
          mapValue // may be untagged in some encodings
        }
        if case let .map(pathMap) = pathCBOR {
          for (pathKey, pathValue) in pathMap {
            guard case let .unsigned(pk) = pathKey else { continue }
            switch pk {
            case 1: // components
              if case let .array(components) = pathValue {
                pathComponents = components
                var parts = ["m"]
                var i = 0
                while i < components.count {
                  if case let .unsigned(index) = components[i] {
                    var part = "\(index)"
                    if i + 1 < components.count {
                      if cborToBool(components[i + 1]) {
                        part += "'"
                      }
                      i += 1 // skip the boolean
                    }
                    parts.append(part)
                  }
                  i += 1
                }
                derivationPath = parts.joined(separator: "/")
              }
            case 2: // source-fingerprint (master fingerprint)
              if case let .unsigned(fp) = pathValue {
                fingerprint = String(format: "%08x", fp)
              }
            case 3: // depth
              if case let .unsigned(d) = pathValue {
                depth = UInt8(d)
              }
            default: break
            }
          }
        }
      case 8: // parent-fingerprint
        if case let .unsigned(pf) = mapValue {
          parentFP = UInt32(pf)
        }
      default:
        break
      }
    }

    // Derive child number from last path component
    var childNumber: UInt32 = 0
    if pathComponents.count >= 2 {
      let lastIdx = pathComponents.count - 2
      if case let .unsigned(idx) = pathComponents[lastIdx] {
        childNumber = UInt32(idx)
        if cborToBool(pathComponents[lastIdx + 1]) {
          childNumber |= 0x8000_0000
        }
      }
    }

    let isTestnet = derivationPath.contains("/1'/")
    let xpub = encodeXpub(keyData: keyData, chainCode: chainCode, isTestnet: isTestnet,
                          depth: depth, parentFingerprint: parentFP, childNumber: childNumber)

    return (xpub: xpub, fingerprint: fingerprint, derivationPath: derivationPath)
  }

  // MARK: - Crypto Output (crypto-output / BCR-2020-010)

  /// Parse a crypto-output UR to reconstruct the text output descriptor string.
  /// crypto-output uses CBOR tags for script expressions:
  ///   400=sh, 401=wsh, 402=pkh, 403=wpkh, 405=multi, 406=sortedmulti
  /// Keys inside are crypto-hdkey maps (tag 303).
  static func parseCryptoOutput(from ur: UR) throws -> String {
    guard ur.type == "crypto-output" else {
      throw AppError.urDecodingFailed("Expected crypto-output, got \(ur.type)")
    }
    return try buildDescriptorString(from: ur.cbor)
  }

  /// Recursively convert CBOR tagged structure into a descriptor string
  private static func buildDescriptorString(from cbor: CBOR) throws -> String {
    switch cbor {
    case let .tagged(tag, inner):
      switch tag.value {
      case 400: return try "sh(\(buildDescriptorString(from: inner)))"
      case 401: return try "wsh(\(buildDescriptorString(from: inner)))"
      case 402: return try "pkh(\(buildDescriptorString(from: inner)))"
      case 403: return try "wpkh(\(buildDescriptorString(from: inner)))"
      case 405: return try buildMultisigString(from: inner, sorted: false)
      case 406, 407:
        // Tag 406 = sorted-multisig per BCR-2020-010
        // Tag 407 = also used for sorted-multisig by some signers (e.g. SeedSigner)
        // Detect by checking if inner map has multisig structure (threshold + keys)
        if isMultisigMap(inner) {
          return try buildMultisigString(from: inner, sorted: true)
        }
        return try buildDescriptorString(from: inner)
      case 303: return try buildKeyString(from: inner)
      default:
        // Check if unknown tag wraps a multisig map
        if isMultisigMap(inner) {
          return try buildMultisigString(from: inner, sorted: true)
        }
        // Recurse through unknown tags (e.g. wrapper tags)
        return try buildDescriptorString(from: inner)
      }
    case .map:
      // Could be an inline crypto-hdkey or a multisig map
      if isMultisigMap(cbor) {
        return try buildMultisigString(from: cbor, sorted: true)
      }
      return try buildKeyString(from: cbor)
    default:
      throw AppError.urDecodingFailed("Unexpected CBOR structure in crypto-output")
    }
  }

  /// Check if a CBOR value looks like a multisig map (has key 1=uint threshold, key 2=array of keys)
  private static func isMultisigMap(_ cbor: CBOR) -> Bool {
    guard case let .map(map) = cbor else { return false }
    var hasThreshold = false
    var hasKeysArray = false
    for (k, v) in map {
      guard case let .unsigned(key) = k else { continue }
      if key == 1, case .unsigned = v {
        hasThreshold = true
      }
      if key == 2, case .array = v {
        hasKeysArray = true
      }
    }
    return hasThreshold && hasKeysArray
  }

  /// Parse a multisig/sortedmulti CBOR map: { 1: threshold, 2: [keys] }
  private static func buildMultisigString(from cbor: CBOR, sorted: Bool) throws -> String {
    guard case let .map(map) = cbor else {
      throw AppError.urDecodingFailed("Expected map for multisig descriptor")
    }

    var threshold: UInt64 = 0
    var keys: [CBOR] = []

    for (k, v) in map {
      guard case let .unsigned(key) = k else { continue }
      switch key {
      case 1: if case let .unsigned(t) = v {
          threshold = t
        }
      case 2: if case let .array(arr) = v {
          keys = arr
        }
      default: break
      }
    }

    let keyStrings = try keys.map { try buildDescriptorString(from: $0) }
    let name = sorted ? "sortedmulti" : "multi"
    return "\(name)(\(threshold),\(keyStrings.joined(separator: ",")))"
  }

  /// Convert a crypto-hdkey CBOR map into a descriptor key string like:
  /// [fingerprint/48'/1'/0'/2']tpubXXX/<0;1>/*
  private static func buildKeyString(from cbor: CBOR) throws -> String {
    guard case let .map(map) = cbor else {
      throw AppError.urDecodingFailed("Expected map for crypto-hdkey")
    }

    var keyData = Data()
    var chainCode = Data()
    var originFingerprint = ""
    var originComponents = ""
    var originDepth: UInt8 = 0
    var originPathComponents: [CBOR] = []
    var childrenComponents = ""
    var parentFingerprintValue: UInt32 = 0

    for (k, v) in map {
      guard case let .unsigned(key) = k else { continue }
      switch key {
      case 3: // key-data
        if case let .bytes(d) = v {
          keyData = d
        }
      case 4: // chain-code
        if case let .bytes(d) = v {
          chainCode = d
        }
      case 6: // origin (crypto-keypath)
        let pathCBOR = unwrapSingleTag(v)
        if case let .map(pathMap) = pathCBOR {
          for (pk, pv) in pathMap {
            if case let .unsigned(pkInt) = pk {
              switch pkInt {
              case 1: // components
                if case let .array(components) = pv {
                  originPathComponents = components
                  originComponents = buildPathComponents(components)
                }
              case 2: // source-fingerprint (master fingerprint)
                if case let .unsigned(fp) = pv {
                  originFingerprint = String(format: "%08x", fp)
                }
              case 3: // depth
                if case let .unsigned(d) = pv {
                  originDepth = UInt8(d)
                }
              default: break
              }
            }
          }
        }
      case 7: // children (crypto-keypath)
        let pathCBOR = unwrapSingleTag(v)
        if case let .map(pathMap) = pathCBOR {
          for (pk, pv) in pathMap {
            if case let .unsigned(pkInt) = pk, pkInt == 1,
               case let .array(components) = pv
            {
              childrenComponents = buildChildrenPath(components)
            }
          }
        }
      case 8: // parent-fingerprint
        if case let .unsigned(pf) = v {
          parentFingerprintValue = UInt32(pf)
        }
      default: break
      }
    }

    // Derive child number from the last path component
    var childNumber: UInt32 = 0
    if originPathComponents.count >= 2 {
      // Path components are [index, hardened, index, hardened, ...]
      // Last pair: second-to-last = index, last = hardened flag
      let lastIdx = originPathComponents.count - 2
      if case let .unsigned(idx) = originPathComponents[lastIdx] {
        childNumber = UInt32(idx)
        if cborToBool(originPathComponents[lastIdx + 1]) {
          childNumber |= 0x8000_0000 // hardened flag
        }
      }
    }

    let isTestnet = originComponents.contains("1'")
      && (originComponents.hasPrefix("48'") || originComponents.hasPrefix("48'/1'"))
    let xpub = encodeXpub(keyData: keyData, chainCode: chainCode, isTestnet: isTestnet,
                          depth: originDepth, parentFingerprint: parentFingerprintValue,
                          childNumber: childNumber)

    var result = ""
    if !originFingerprint.isEmpty, !originComponents.isEmpty {
      result += "[\(originFingerprint)/\(originComponents)]"
    }
    result += xpub
    if !childrenComponents.isEmpty {
      result += "/\(childrenComponents)"
    } else {
      // Default: BIP-389 multipath wildcard for standard multisig
      result += "/<0;1>/*"
    }

    return result
  }

  /// Build a derivation path string from CBOR components array (index, hardened pairs)
  private static func buildPathComponents(_ components: [CBOR]) -> String {
    var parts: [String] = []
    var i = 0
    while i < components.count {
      if case let .unsigned(index) = components[i] {
        var part = "\(index)"
        if i + 1 < components.count {
          let isHardened = cborToBool(components[i + 1])
          if isHardened {
            part += "'"
          }
          i += 1 // skip the boolean
        }
        parts.append(part)
      } else if case .array = components[i] {
        // Empty array [] = wildcard *
        parts.append("*")
      }
      i += 1
    }
    return parts.joined(separator: "/")
  }

  /// Build children path string, handling wildcards and multipath <0;1>/*
  private static func buildChildrenPath(_ components: [CBOR]) -> String {
    // Check for multipath: two sets of components representing <0;1>/*
    // Some encoders put this as a pair of sub-arrays: [[0,false],[1,false]]
    // Others use a flat list with the wildcard at the end

    // Handle flat components with wildcard
    var parts: [String] = []
    var i = 0
    while i < components.count {
      switch components[i] {
      case let .unsigned(index):
        var part = "\(index)"
        if i + 1 < components.count {
          let isHardened = cborToBool(components[i + 1])
          if isHardened {
            part += "'"
          }
          i += 1
        }
        parts.append(part)
      case let .array(subComponents):
        if subComponents.isEmpty {
          // Empty array = wildcard *
          parts.append("*")
        } else {
          // Sub-array might encode multipath pairs
          let subPath = buildChildrenPath(subComponents)
          parts.append(subPath)
        }
      case let .tagged(_, inner):
        // Unwrap tags and recurse
        if case let .array(subComponents) = inner {
          let subPath = buildChildrenPath(subComponents)
          parts.append(subPath)
        }
      default:
        break
      }
      i += 1
    }

    return parts.joined(separator: "/")

    // If we got just "0/*", return as-is (single path)
    // If empty, return empty and let caller add default
  }

  // MARK: - Encode Crypto Output (BCR-2020-010)

  /// Encode a text output descriptor into a crypto-output UR with proper CBOR tag structure.
  /// Supports wsh(sortedmulti(...)) and wsh(multi(...)) descriptor formats.
  static func encodeCryptoOutput(descriptor: String) throws -> UR {
    // Strip descriptor checksum if present (e.g. #abc123)
    var desc = descriptor
    if let hashIdx = desc.lastIndex(of: "#") {
      desc = String(desc[desc.startIndex ..< hashIdx])
    }
    let cbor = try encodeOutputDescriptor(desc.trimmingCharacters(in: .whitespaces))
    return try UR(type: "crypto-output", cbor: cbor)
  }

  /// Recursively encode a descriptor string into CBOR tagged structure
  private static func encodeOutputDescriptor(_ desc: String) throws -> CBOR {
    if desc.hasPrefix("wsh("), desc.hasSuffix(")") {
      let inner = String(desc.dropFirst(4).dropLast(1))
      return try .tagged(.outputWitnessScriptHash, encodeOutputDescriptor(inner))
    }
    if desc.hasPrefix("sh("), desc.hasSuffix(")") {
      let inner = String(desc.dropFirst(3).dropLast(1))
      return try .tagged(.outputScriptHash, encodeOutputDescriptor(inner))
    }
    if desc.hasPrefix("sortedmulti("), desc.hasSuffix(")") {
      let inner = String(desc.dropFirst(12).dropLast(1))
      return try .tagged(.outputSortedMultisig, encodeMultisigMapCBOR(inner))
    }
    if desc.hasPrefix("multi("), desc.hasSuffix(")") {
      let inner = String(desc.dropFirst(6).dropLast(1))
      return try .tagged(.outputMultisig, encodeMultisigMapCBOR(inner))
    }
    throw AppError.urDecodingFailed("Unsupported descriptor format for UR encoding")
  }

  /// Encode multisig content "threshold,key1,key2,..." into CBOR map { 1: threshold, 2: [keys] }
  private static func encodeMultisigMapCBOR(_ content: String) throws -> CBOR {
    let parts = splitDescriptorArgs(content)
    guard let first = parts.first, let threshold = UInt64(first.trimmingCharacters(in: .whitespaces)) else {
      throw AppError.urDecodingFailed("Invalid multisig threshold")
    }
    let keyCBORs = try parts.dropFirst().map { try encodeHDKeyExpression($0.trimmingCharacters(in: .whitespaces)) }
    var map = Map()
    map.insert(CBOR.unsigned(1), CBOR.unsigned(threshold))
    map.insert(CBOR.unsigned(2), CBOR.array(keyCBORs))
    return .map(map)
  }

  /// Split comma-separated arguments respecting brackets and angle brackets
  private static func splitDescriptorArgs(_ str: String) -> [String] {
    var result: [String] = []
    var current = ""
    var depth = 0
    for char in str {
      if char == "[" || char == "(" || char == "<" {
        depth += 1
      }
      if char == "]" || char == ")" || char == ">" {
        depth -= 1
      }
      if char == ",", depth == 0 {
        result.append(current)
        current = ""
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty {
      result.append(current)
    }
    return result
  }

  /// Encode a key expression like "[fp/48'/1'/0'/2']tpubXXX/<0;1>/*" into tagged crypto-hdkey CBOR
  private static func encodeHDKeyExpression(_ keyExpr: String) throws -> CBOR {
    var expr = keyExpr

    // Parse origin [fingerprint/derivation-path]
    var originFingerprint: UInt32 = 0
    var originPath: [(index: UInt32, hardened: Bool)] = []

    if expr.hasPrefix("[") {
      guard let closeIdx = expr.firstIndex(of: "]") else {
        throw AppError.urDecodingFailed("Invalid key origin bracket")
      }
      let originStr = String(expr[expr.index(after: expr.startIndex) ..< closeIdx])
      expr = String(expr[expr.index(after: closeIdx)...])

      let originParts = originStr.split(separator: "/")
      if let fpStr = originParts.first, fpStr.count == 8 {
        originFingerprint = UInt32(fpStr, radix: 16) ?? 0
      }
      for part in originParts.dropFirst() {
        let hardened = part.hasSuffix("'") || part.hasSuffix("h")
        let cleaned = part.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "h", with: "")
        if let index = UInt32(cleaned) {
          originPath.append((index: index, hardened: hardened))
        }
      }
    }

    // Separate xpub from children path
    var xpubStr = expr

    if let slashIdx = expr.firstIndex(of: "/") {
      xpubStr = String(expr[expr.startIndex ..< slashIdx])
    }

    // Decode xpub/tpub to extract key-data, chain-code, depth, parent-fingerprint
    guard let decoded = base58CheckDecode(xpubStr), decoded.count == 78 else {
      throw AppError.urDecodingFailed("Failed to decode xpub in key expression")
    }

    let depth = decoded[4]
    let parentFP = UInt32(decoded[5]) << 24 | UInt32(decoded[6]) << 16
      | UInt32(decoded[7]) << 8 | UInt32(decoded[8])
    let chainCode = Data(decoded[13 ..< 45])
    let keyData = Data(decoded[45 ..< 78])

    // Build crypto-hdkey CBOR map (BCR-2020-007)
    var hdKeyMap = Map()

    // Key 2: is-private = false (public key)
    hdKeyMap.insert(CBOR.unsigned(2), CBOR.simple(.false))
    // Key 3: key-data (33 bytes compressed public key)
    hdKeyMap.insert(CBOR.unsigned(3), CBOR.bytes(keyData))
    // Key 4: chain-code (32 bytes)
    hdKeyMap.insert(CBOR.unsigned(4), CBOR.bytes(chainCode))

    // Key 5: use-info (crypto-coin-info tag 305)
    var coinInfoMap = Map()
    coinInfoMap.insert(CBOR.unsigned(1), CBOR.unsigned(0)) // coin_type = Bitcoin
    let isTestnet = xpubStr.hasPrefix("tpub")
    if isTestnet {
      coinInfoMap.insert(CBOR.unsigned(2), CBOR.unsigned(1)) // network = Testnet
    } else {
      coinInfoMap.insert(CBOR.unsigned(2), CBOR.unsigned(0)) // network = Mainnet
    }
    hdKeyMap.insert(CBOR.unsigned(5), CBOR.tagged(Tag(305), CBOR.map(coinInfoMap)))

    // Key 6: origin keypath (tagged 304 crypto-keypath)
    if !originPath.isEmpty {
      var pathComponents: [CBOR] = []
      for component in originPath {
        pathComponents.append(.unsigned(UInt64(component.index)))
        pathComponents.append(component.hardened ? .simple(.true) : .simple(.false))
      }
      var keypathMap = Map()
      keypathMap.insert(CBOR.unsigned(1), CBOR.array(pathComponents))
      if originFingerprint != 0 {
        keypathMap.insert(CBOR.unsigned(2), CBOR.unsigned(UInt64(originFingerprint)))
      }
      keypathMap.insert(CBOR.unsigned(3), CBOR.unsigned(UInt64(depth)))
      hdKeyMap.insert(CBOR.unsigned(6), CBOR.tagged(.derivationPathV1, CBOR.map(keypathMap)))
    }

    // Key 8: parent-fingerprint
    if parentFP != 0 {
      hdKeyMap.insert(CBOR.unsigned(8), CBOR.unsigned(UInt64(parentFP)))
    }

    return .tagged(.hdKeyV1, CBOR.map(hdKeyMap))
  }

  /// Check if a CBOR value represents boolean true
  private static func cborToBool(_ cbor: CBOR) -> Bool {
    switch cbor {
    case let .simple(s):
      switch s {
      case .true: true
      default: false
      }
    case let .tagged(_, inner):
      cborToBool(inner)
    case let .unsigned(v):
      v == 1
    default:
      false
    }
  }

  /// Unwrap a single CBOR tag layer (e.g. tag 304 wrapping a keypath map)
  private static func unwrapSingleTag(_ cbor: CBOR) -> CBOR {
    if case let .tagged(_, inner) = cbor {
      return inner
    }
    return cbor
  }

  // MARK: - Process UR into app result

  // MARK: - Text Encoded xpub

  /// Parse a text-encoded extended public key with optional fingerprint and derivation path
  /// e.g., "[7a13a7b1/48h/1h/0h/2h]Vpub5mKYi..."
  static func parseTextEncodedXpub(_ text: String) -> AppURResult? {
    let pattern = "^\\[([a-fA-F0-9]{8})(.*?)\\]([a-zA-Z0-9]{111,})$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

    let range = NSRange(text.startIndex ..< text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      // Check if it's just a raw xpub/tpub/Zpub/Vpub etc. without the `[...]` prefix
      let rawPattern = "^([a-zA-Z0-9]{111,})$"
      guard let rawRegex = try? NSRegularExpression(pattern: rawPattern) else { return nil }
      if rawRegex.firstMatch(in: text, options: [], range: range) != nil {
        if ["xpub", "tpub", "Zpub", "zpub", "Ypub", "ypub", "Vpub", "vpub", "Upub", "upub"].contains(where: text.hasPrefix) {
          return .hdKey(xpub: text, fingerprint: "", derivationPath: "")
        }
      }
      return nil
    }

    let fingerprintRange = match.range(at: 1)
    let pathRange = match.range(at: 2)
    let xpubRange = match.range(at: 3)

    guard let fpRange = Range(fingerprintRange, in: text),
          let pRange = Range(pathRange, in: text),
          let xRange = Range(xpubRange, in: text)
    else {
      return nil
    }

    let fingerprint = String(text[fpRange])
    var derivationPath = String(text[pRange])
    let xpub = String(text[xRange])

    if !derivationPath.isEmpty {
      derivationPath = derivationPath.replacingOccurrences(of: "h", with: "'")
      derivationPath = derivationPath.replacingOccurrences(of: "H", with: "'")
      if !derivationPath.hasPrefix("m") {
        if derivationPath.hasPrefix("/") {
          derivationPath = "m" + derivationPath
        } else {
          derivationPath = "m/" + derivationPath
        }
      }
    }

    return .hdKey(xpub: xpub, fingerprint: fingerprint, derivationPath: derivationPath)
  }

  /// Try to extract a wallet descriptor from a JSON string (e.g. Specter Desktop export).
  /// Returns the descriptor string if found, nil otherwise.
  static func extractDescriptorFromJSON(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let descriptor = json["descriptor"] as? String,
          !descriptor.isEmpty
    else { return nil }
    return descriptor
  }

  static func processUR(_ ur: UR) -> AppURResult {
    switch ur.type {
    case "crypto-psbt":
      do {
        let data = try decodePSBT(from: ur)
        logger.info("Decoded crypto-psbt UR: \(data.count) bytes")
        return .psbt(data)
      } catch {
        logger.error("Failed to decode crypto-psbt UR: \(error)")
      }
    case "crypto-hdkey":
      do {
        let result = try parseHDKey(from: ur)
        logger.info("Decoded crypto-hdkey UR: fingerprint \(result.fingerprint), path \(result.derivationPath), xpub \(result.xpub)")
        return .hdKey(xpub: result.xpub, fingerprint: result.fingerprint, derivationPath: result.derivationPath)
      } catch {
        logger.error("Failed to decode crypto-hdkey UR: \(error)")
      }
    case "crypto-account":
      do {
        let result = try parseCryptoAccount(from: ur)
        logger.info("Decoded crypto-account UR: fingerprint \(result.fingerprint), path \(result.derivationPath), xpub \(result.xpub)")
        return .hdKey(xpub: result.xpub, fingerprint: result.fingerprint, derivationPath: result.derivationPath)
      } catch {
        logger.error("Failed to decode crypto-account UR: \(error)")
      }
    case "crypto-output":
      do {
        let descriptor = try parseCryptoOutput(from: ur)
        logger.info("Decoded crypto-output UR: \(descriptor)")
        return .descriptor(descriptor)
      } catch {
        logger.error("Failed to decode crypto-output UR: \(error)")
      }
    case "bytes":
      if case let .bytes(data) = ur.cbor {
        logger.info("Decoded bytes UR: \(data.count) bytes")
        return .rawBytes(data)
      }
      logger.error("bytes UR had unexpected CBOR structure")
    default:
      logger.warning("Unrecognized UR type: \(ur.type)")
    }
    return .unknown(ur.type)
  }

  /// Process a single-part UR string (e.g. "ur:crypto-account/OEADCY...")
  static func processURString(_ urString: String) -> AppURResult {
    guard let ur = try? UR(urString: urString) else {
      return .unknown("invalid")
    }
    return processUR(ur)
  }

  /// Process a multi-part UR from an array of part strings (fountain-coded).
  /// Parts can be provided in any order and may include duplicates.
  static func processMultiPartURStrings(_ parts: [String]) -> AppURResult {
    let decoder = URDecoder()
    for part in parts {
      let _ = decoder.receivePart(part)
      if case let .success(ur) = decoder.result {
        return processUR(ur)
      }
    }
    return .unknown("incomplete")
  }

  // MARK: - Xpub Conversion

  enum XpubFormat {
    case standard // xpub, tpub
    case slip132 // Zpub, Vpub
  }

  // Standard xpub version: 0x0488B21E
  // Standard tpub version: 0x043587CF
  // P2WSH Zpub version: 0x02aa7ed3
  // P2WSH Vpub version: 0x02575483

  /// Converts an extended public key to the desired format for the current network.
  static func convertXpub(_ pubKey: String, to format: XpubFormat, isTestnet: Bool) -> String? {
    guard pubKey.hasPrefix("xpub") || pubKey.hasPrefix("tpub") || pubKey.hasPrefix("Zpub") || pubKey.hasPrefix("Vpub") else {
      return nil
    }
    guard let decoded = base58CheckDecode(pubKey) else { return nil }
    guard decoded.count == 78 else { return nil }

    var newPayload = Data()

    switch format {
    case .standard:
      if isTestnet {
        newPayload.append(contentsOf: [0x04, 0x35, 0x87, 0xCF]) // tpub version
      } else {
        newPayload.append(contentsOf: [0x04, 0x88, 0xB2, 0x1E]) // xpub version
      }
    case .slip132:
      if isTestnet {
        newPayload.append(contentsOf: [0x02, 0x57, 0x54, 0x83]) // Vpub version
      } else {
        newPayload.append(contentsOf: [0x02, 0xAA, 0x7E, 0xD3]) // Zpub version
      }
    }

    newPayload.append(decoded[4...])
    return base58CheckEncode(newPayload)
  }

  /// Converts an extended public key (xpub, tpub, Zpub, Vpub) to the standard xpub or tpub for the current network.
  static func normalizeXpub(_ pubKey: String, isTestnet: Bool) -> String? {
    convertXpub(pubKey, to: .standard, isTestnet: isTestnet)
  }

  /// Toggles the format between standard (xpub/tpub) and SLIP132 (Zpub/Vpub)
  static func toggleXpubFormat(_ pubKey: String, isTestnet: Bool) -> String? {
    if pubKey.hasPrefix("Zpub") || pubKey.hasPrefix("Vpub") {
      convertXpub(pubKey, to: .standard, isTestnet: isTestnet)
    } else {
      convertXpub(pubKey, to: .slip132, isTestnet: isTestnet)
    }
  }

  // MARK: - Xpub Encoding

  private static func encodeXpub(keyData: Data, chainCode: Data, isTestnet: Bool) -> String {
    encodeXpub(keyData: keyData, chainCode: chainCode, isTestnet: isTestnet,
               depth: 0, parentFingerprint: 0, childNumber: 0)
  }

  private static func encodeXpub(keyData: Data, chainCode: Data, isTestnet: Bool,
                                 depth: UInt8, parentFingerprint: UInt32, childNumber: UInt32) -> String
  {
    guard keyData.count == 33, chainCode.count == 32 else {
      return ""
    }

    let version: [UInt8] = isTestnet ? [0x04, 0x35, 0x87, 0xCF] : [0x04, 0x88, 0xB2, 0x1E]

    var payload = Data()
    payload.append(contentsOf: version)
    payload.append(depth)
    payload.append(contentsOf: withUnsafeBytes(of: parentFingerprint.bigEndian) { Array($0) })
    payload.append(contentsOf: withUnsafeBytes(of: childNumber.bigEndian) { Array($0) })
    payload.append(chainCode)
    payload.append(keyData)

    return base58CheckEncode(payload)
  }

  static func base58CheckDecode(_ string: String) -> Data? {
    let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    var alphabetMap: [Character: UInt32] = [:]
    for (i, c) in alphabet.enumerated() {
      alphabetMap[c] = UInt32(i)
    }

    var bytes: [UInt8] = []
    for char in string {
      guard let value = alphabetMap[char] else { return nil }
      var carry = value
      for i in bytes.indices {
        carry += UInt32(bytes[i]) * 58
        bytes[i] = UInt8(carry & 0xFF)
        carry >>= 8
      }
      while carry > 0 {
        bytes.append(UInt8(carry & 0xFF))
        carry >>= 8
      }
    }

    // Add leading zeros
    for char in string {
      if char == "1" {
        bytes.append(0)
      } else {
        break
      }
    }

    let decoded = Data(bytes.reversed())
    guard decoded.count >= 4 else { return nil }

    let payload = decoded.prefix(decoded.count - 4)
    let checksum = decoded.suffix(4)
    let expectedChecksum = sha256d(payload).prefix(4)
    guard checksum == expectedChecksum else { return nil }

    return payload
  }

  private static func base58CheckEncode(_ data: Data) -> String {
    let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    let checksum = sha256d(data).prefix(4)
    let bytes = Array(data) + Array(checksum)

    var num: [UInt32] = []
    for byte in bytes {
      var carry = UInt32(byte)
      for i in num.indices {
        carry += num[i] << 8
        num[i] = carry % 58
        carry /= 58
      }
      while carry > 0 {
        num.append(carry % 58)
        carry /= 58
      }
    }

    var result = String(num.reversed().map { alphabet[Int($0)] })

    for byte in bytes {
      if byte == 0 {
        result = "1" + result
      } else {
        break
      }
    }

    return result
  }

  // MARK: - Debug

  /// Dump CBOR structure for debugging UR parsing issues
  static func debugCBOR(_ urString: String) -> String {
    guard let ur = try? UR(urString: urString) else {
      return "Failed to decode UR string"
    }
    return "type: \(ur.type)\ncbor: \(describeCBOR(ur.cbor, indent: 0))"
  }

  private static func describeCBOR(_ cbor: CBOR, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch cbor {
    case let .unsigned(v): return "unsigned(\(v))"
    case let .negative(v): return "negative(\(v))"
    case let .bytes(d): return "bytes(\(d.count) bytes: \(d.prefix(8).map { String(format: "%02x", $0) }.joined())...)"
    case let .text(s): return "text(\"\(s)\")"
    case let .simple(s): return "simple(\(s))"
    case let .tagged(tag, inner):
      return "tagged(\(tag), \(describeCBOR(inner, indent: indent)))"
    case let .array(arr):
      let items = arr.map { "\(pad)  \(describeCBOR($0, indent: indent + 1))" }.joined(separator: ",\n")
      return "array[\(arr.count)]:\n\(items)"
    case let .map(map):
      var entries: [String] = []
      for (k, v) in map {
        entries.append("\(pad)  \(describeCBOR(k, indent: indent + 1)): \(describeCBOR(v, indent: indent + 1))")
      }
      return "map{\(map.count)}:\n\(entries.joined(separator: ",\n"))"
    }
  }

  private static func sha256d(_ data: Data) -> Data {
    var hash1 = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash1)
    }
    var hash2 = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    hash1.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(hash1.count), &hash2)
    }
    return Data(hash2)
  }
}

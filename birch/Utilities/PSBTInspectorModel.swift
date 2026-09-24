import Foundation

// MARK: - Field model

enum PSBTFieldTag: Hashable {
  case inQR
  case signing
  /// A P2WSH (or P2SH) signer cannot produce a signature without this field
  case requiredToSign
  /// Lets a signer check for itself that an output returns to the wallet
  case verifiesChange
  case v2
  case unrecognized

  var label: String {
    switch self {
    case .inQR: "In QR payload"
    case .signing: "Signing material"
    case .requiredToSign: "Required to sign"
    case .verifiesChange: "Verifies change"
    case .v2: "v2"
    case .unrecognized: "Unrecognized"
    }
  }

  /// Display order for tag chips
  static let order: [PSBTFieldTag] = [.requiredToSign, .verifiesChange, .signing, .inQR, .v2, .unrecognized]
}

enum PartTint {
  case own, input, output, global, absent
}

struct FieldPart: Equatable {
  let label: String
  let bytes: Int
  let tint: PartTint
  let definition: String
}

struct PSBTField: Identifiable {
  let id: String
  let section: PSBTMapLocation
  let keyType: UInt64
  /// "witness_script", "bip32_derivation ×3"
  let name: String
  /// Records collapsed into this row
  let count: Int
  /// Summed serialized size
  let bytes: Int
  /// Byte offset of the first record
  let offset: Int
  let definition: String
  let extended: String
  let tags: Set<PSBTFieldTag>
  let partsLabel: String?
  let parts: [FieldPart]?
  let records: [PSBTRecord]

  var keyTypeLabel: String {
    String(format: "0x%02llX", keyType)
  }

  var sortedTags: [PSBTFieldTag] {
    PSBTFieldTag.order.filter { tags.contains($0) }
  }
}

struct PSBTSection: Identifiable {
  let location: PSBTMapLocation
  let label: String
  let fields: [PSBTField]
  /// Explanation shown in place of rows when the map holds no records
  let emptyNote: String?

  var id: String {
    location.id
  }

  var bytes: Int {
    fields.reduce(0) { $0 + $1.bytes }
  }

  var recordCount: Int {
    fields.reduce(0) { $0 + $1.count }
  }
}

// MARK: - Lenses

enum PSBTLens: String, CaseIterable, Identifiable {
  case all, inQR, signing

  var id: String {
    rawValue
  }

  var label: String {
    switch self {
    case .all: "All fields"
    case .inQR: "In QR"
    case .signing: "Signing"
    }
  }
}

// MARK: - Inspector model

struct PSBTInspectorModel: Sendable {
  let parsed: ParsedPSBT
  let sections: [PSBTSection]
  let compactEnabled: Bool
  /// Size of the payload `PSBTCompactor` produces for this PSBT
  let compactBytes: Int
  let requiredSignatures: Int?
  let totalKeys: Int?
  let networkName: String?
  let isFinalized: Bool
  let absentFieldNames: [String]
  private let signatureCounts: [Int]
  private let finalizedInputs: Int

  var fields: [PSBTField] {
    sections.flatMap(\.fields)
  }

  var totalRecords: Int {
    parsed.records.count
  }

  /// Bytes that belong to no record: the 5-byte magic plus one separator per map
  var framingBytes: Int {
    5 + 1 + parsed.inputCount + parsed.outputCount
  }

  /// Size of the PSBT the animated QR actually encodes
  var qrPayloadBytes: Int {
    compactEnabled ? compactBytes : parsed.totalBytes
  }

  static func build(
    psbtBytes: Data,
    compactEnabled: Bool,
    cosigners: [(label: String, fingerprint: String)],
    requiredSignatures: Int?,
    networkName: String?
  ) throws -> PSBTInspectorModel {
    let parsed = try PSBTParser.parse(psbtBytes)

    // What the QR drops is whatever PSBTCompactor actually removes: diff the records
    // of the real compacted payload against the original.
    let compacted = PSBTCompactor.compact(psbtBytes)
    var dropped = Set<PSBTRecord.Identity>()
    if compacted != psbtBytes, let compactParsed = try? PSBTParser.parse(compacted) {
      let kept = Set(compactParsed.records.map(\.identity))
      dropped = Set(parsed.records.map(\.identity).filter { !kept.contains($0) })
    }

    // Prefer the policy the PSBT itself states over the caller's wallet figures
    let policy = parsed.records
      .first { $0.keyType == 0x05 && $0.map != .global && PSBTParser.multisigSummary($0.value) != nil }
      .flatMap { PSBTParser.multisigSummary($0.value) }
    let m = policy?.m ?? requiredSignatures
    let n = policy?.n ?? (cosigners.isEmpty ? nil : cosigners.count)

    // Only signatures that can count toward an input's threshold
    let signatureCounts = (0 ..< parsed.inputCount).map { i in
      parsed.partialSignatures(input: i).counted.count
        + parsed.records(in: .input(i)).count(where: { $0.keyType == 0x13 })
    }
    let finalizedInputs = (0 ..< parsed.inputCount).count(where: { i in
      parsed.records(in: .input(i)).contains { $0.keyType == 0x07 || $0.keyType == 0x08 }
    })
    let isFinalized = parsed.inputCount > 0 && finalizedInputs == parsed.inputCount

    let context = PSBTFieldCopy.Context(
      parsed: parsed,
      requiredSignatures: m,
      totalKeys: n,
      cosigners: cosigners,
      compactDrops: compactEnabled && !dropped.isEmpty
    )

    var sections: [PSBTSection] = []
    var locations: [PSBTMapLocation] = [.global]
    locations += (0 ..< parsed.inputCount).map { .input($0) }
    locations += (0 ..< parsed.outputCount).map { .output($0) }

    for location in locations {
      let records = parsed.records(in: location)
      // Group records of one key type into a single row, in first-seen order
      var order: [UInt64] = []
      var groups: [UInt64: [PSBTRecord]] = [:]
      for record in records {
        if groups[record.keyType] == nil {
          order.append(record.keyType)
        }
        groups[record.keyType, default: []].append(record)
      }

      let fields = order.map { keyType -> PSBTField in
        let group = groups[keyType] ?? []
        let copy = PSBTFieldCopy.copy(keyType: keyType, location: location, records: group, context: context)
        var tags = Set<PSBTFieldTag>()
        if !compactEnabled || group.contains(where: { !dropped.contains($0.identity) }) {
          tags.insert(.inQR)
        }
        if isSigning(keyType: keyType, location: location) {
          tags.insert(.signing)
        }
        if copy.requiredToSign {
          tags.insert(.requiredToSign)
        }
        if copy.verifiesChange {
          tags.insert(.verifiesChange)
        }
        if copy.isV2 {
          tags.insert(.v2)
        }
        if copy.isUnrecognized {
          tags.insert(.unrecognized)
        }
        return PSBTField(
          id: "\(location.id)-\(keyType)",
          section: location,
          keyType: keyType,
          name: group.count > 1 ? "\(copy.name) ×\(group.count)" : copy.name,
          count: group.count,
          bytes: group.reduce(0) { $0 + $1.length },
          offset: group.first?.offset ?? 0,
          definition: copy.definition,
          extended: copy.extended,
          tags: tags,
          partsLabel: copy.partsLabel,
          parts: copy.parts,
          records: group
        )
      }

      sections.append(PSBTSection(
        location: location,
        label: sectionLabel(location),
        fields: fields,
        emptyNote: fields.isEmpty ? PSBTFieldCopy.emptySectionNote(location: location, context: context) : nil
      ))
    }

    let presentNames = Set(sections.flatMap(\.fields).map { $0.name.components(separatedBy: " ×").first ?? $0.name })
    let notable = [
      "non_witness_utxo", "witness_script", "redeem_script", "partial_sig", "final_scriptwitness",
      "tap_key_sig", "tap_internal_key", "tap_bip32_derivation", "proprietary",
    ]
    let absent = notable.filter { !presentNames.contains($0) }

    return PSBTInspectorModel(
      parsed: parsed,
      sections: sections,
      compactEnabled: compactEnabled,
      compactBytes: compacted.count,
      requiredSignatures: m,
      totalKeys: n,
      networkName: networkName,
      isFinalized: isFinalized,
      absentFieldNames: absent,
      signatureCounts: signatureCounts,
      finalizedInputs: finalizedInputs
    )
  }

  // MARK: Membership rules

  private static func isSigning(keyType: UInt64, location: PSBTMapLocation) -> Bool {
    guard case .input = location else { return false }
    return [0x02, 0x07, 0x08, 0x13, 0x14].contains(keyType)
  }

  private static func sectionLabel(_ location: PSBTMapLocation) -> String {
    switch location {
    case .global: "Global"
    case let .input(i): "Input \(i)"
    case let .output(i): "Output \(i)"
    }
  }

  // MARK: Lens queries

  func matches(_ field: PSBTField, lens: PSBTLens) -> Bool {
    switch lens {
    case .all: true
    case .inQR: field.tags.contains(.inQR)
    case .signing: field.tags.contains(.signing)
    }
  }

  func note(for lens: PSBTLens) -> String {
    switch lens {
    case .all:
      return "Every key-value pair in the PSBT."
    case .inQR:
      if !compactEnabled {
        return "What the animated QR payload actually carries. Compact PSBT is off, so that is everything."
      }
      return compactBytes == parsed.totalBytes
        ? "What the animated QR payload actually carries. Compact PSBT is on, but there is nothing in this PSBT for it to strip."
        : "What the animated QR payload actually carries. Compact PSBT is on, so the dimmed fields are left out."
    case .signing:
      return signingNote
    }
  }

  private var signingNote: String {
    if isFinalized {
      return "Every input is finalized. Per BIP-174 the finalizer cleared the partial signatures and scripts, so the map is short on purpose."
    }
    let maxSigs = signatureCounts.max() ?? 0
    if maxSigs == 0, finalizedInputs == 0 {
      return "No signatures yet. Nothing here until a cosigner device signs and the PSBT is scanned back."
    }
    let minSigs = signatureCounts.min() ?? 0
    let range = minSigs == maxSigs ? "\(minSigs)" : "\(minSigs) to \(maxSigs)"
    var note = "Signature material. "
    if let m = requiredSignatures {
      note += "\(range) of \(m) required signatures per input"
    } else {
      note += "\(range) signatures per input"
    }
    if finalizedInputs > 0 {
      note += ", \(finalizedInputs) of \(parsed.inputCount) inputs finalized"
    }
    return note + "."
  }

  func stat(for lens: PSBTLens) -> String {
    switch lens {
    case .all:
      return "\(totalRecords) pairs · \(parsed.totalBytes.formatted()) B"
    case .inQR:
      // The real payload size, so it matches the QR screen: records plus the magic
      // bytes and map separators
      let pairs = fields.filter { matches($0, lens: .inQR) }.reduce(0) { $0 + $1.count }
      return "\(pairs) of \(totalRecords) pairs · \(qrPayloadBytes.formatted()) B"
    default:
      let hits = fields.filter { matches($0, lens: lens) }
      let pairs = hits.reduce(0) { $0 + $1.count }
      let bytes = hits.reduce(0) { $0 + $1.bytes }
      return "\(pairs) of \(totalRecords) pairs · \(bytes.formatted()) B"
    }
  }

  func sectionMeta(_ section: PSBTSection, lens: PSBTLens) -> String {
    guard !section.fields.isEmpty else { return "no fields · 0 B" }
    let hits = section.fields.filter { matches($0, lens: lens) }
    let hitPairs = hits.reduce(0) { $0 + $1.count }
    switch lens {
    case .all:
      return "\(section.recordCount) pairs · \(section.bytes.formatted()) B"
    default:
      return "\(hitPairs) of \(section.recordCount) · \(section.bytes.formatted()) B"
    }
  }

  /// "2-of-3 · 2 inputs · 2 outputs · Testnet4"
  var subtitle: String {
    var parts: [String] = []
    if let m = requiredSignatures, let n = totalKeys {
      parts.append("\(m)-of-\(n)")
    }
    parts.append("\(parsed.inputCount) input\(parsed.inputCount == 1 ? "" : "s")")
    parts.append("\(parsed.outputCount) output\(parsed.outputCount == 1 ? "" : "s")")
    if parsed.version == 2 {
      parts.append("PSBT v2")
    }
    if let networkName {
      parts.append(networkName)
    }
    return parts.joined(separator: " · ")
  }
}

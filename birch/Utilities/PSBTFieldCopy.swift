import Foundation

/// Written definitions for every PSBT field the inspector shows.
///
/// The copy is written for Birch's actual setting: a watch-only coordinator building
/// native P2WSH `sortedmulti` PSBTs for air-gapped signing devices. Each definition
/// leads with the field's purpose, names its spec constant, explains why it is the
/// size it is, and says what a signer should (and should not) trust about it. An
/// air-gapped device has to assume the coordinator that wrote the PSBT could be
/// compromised: fingerprints, derivation paths and xpubs in the file are claims to be
/// verified against the device's own seed and a wallet descriptor it already trusts,
/// never facts.
enum PSBTFieldCopy {
  struct Context {
    let parsed: ParsedPSBT
    /// m of the multisig policy, when known
    let requiredSignatures: Int?
    /// n of the multisig policy, when known
    let totalKeys: Int?
    let cosigners: [(label: String, fingerprint: String)]
    /// Whether the QR payload leaves anything out: Compact PSBT is on and has something to strip
    let compactDrops: Bool

    func cosignerLabel(for fingerprint: String) -> String? {
      let target = CosignerInfo.normalizedFingerprint(fingerprint)
      return cosigners.first { CosignerInfo.normalizedFingerprint($0.fingerprint) == target }?.label
    }

    var policy: String {
      if let m = requiredSignatures, let n = totalKeys {
        return "\(m)-of-\(n)"
      }
      return "multisig"
    }

    var cosignersPhrase: String {
      totalKeys.map { "\($0) cosigners" } ?? "cosigners"
    }
  }

  struct Copy {
    var name: String
    var definition: String
    var extended: String = ""
    var partsLabel: String?
    var parts: [FieldPart]?
    /// A P2WSH (or P2SH) signer cannot produce a signature without this field
    var requiredToSign = false
    /// Lets a signer check for itself that an output returns to the wallet
    var verifiesChange = false
    var isV2 = false
    var isUnrecognized = false
  }

  static func copy(keyType: UInt64, location: PSBTMapLocation, records: [PSBTRecord], context: Context) -> Copy {
    switch location {
    case .global: globalCopy(keyType: keyType, records: records, context: context)
    case .input: inputCopy(keyType: keyType, records: records, context: context)
    case .output: outputCopy(keyType: keyType, records: records, context: context)
    }
  }

  // MARK: - Global

  private static func globalCopy(keyType: UInt64, records: [PSBTRecord], context: Context) -> Copy {
    let record = records.first
    switch keyType {
    case 0x00:
      var copy = Copy(
        name: "unsigned_tx",
        definition: "PSBT_GLOBAL_UNSIGNED_TX. Gives every cosigner a shared reference for exactly which transaction they are agreeing to sign: its version, every input's outpoint and sequence, every output's amount and scriptPubKey, and the locktime.",
        extended: "A signature is a commitment to a sighash, and for a P2WSH input that sighash (BIP-143) is computed from this transaction's structure plus the input's own amount and witness script. If two cosigners worked from even slightly different versions of it, their signatures would commit to different sighashes and could never be combined into one valid transaction. So nothing in here may change once the first signature exists. It is serialized the pre-segwit way, with every scriptSig empty and no witness data, because none exists yet; that is also the serialization the txid is computed from, so the txid stays fixed through signing. This blob is the only place the outputs' amounts and destinations appear. The per-output maps below carry proof metadata, not the payment itself."
      )
      if let record, let tx = context.parsed.unsignedTx {
        copy.partsLabel = "Inside the blob"
        copy.parts = unsignedTxParts(record: record, tx: tx, context: context)
      }
      return copy
    case 0x01:
      let count = records.count
      var parts: [FieldPart] = []
      for record in records {
        let derivation = PSBTParser.derivation(from: record.value)
        let fingerprint = derivation?.fingerprint ?? "????????"
        let known = context.cosignerLabel(for: fingerprint)
        let path = derivation?.path ?? "an unreadable path"
        let levels = derivation?.levels ?? 0
        var definition = "\(record.length) bytes: a length byte, the type byte 0x01, and the \(record.keyData.count)-byte serialized xpub (4 version, 1 depth, 4 parent fingerprint, 4 child number, 32 chain code, 33 public key); then a length byte, the 4-byte master fingerprint, and \(path) as \(levels) × 4-byte little-endian integers."
        if known == nil {
          definition += " This fingerprint does not match any cosigner saved in this wallet."
        }
        parts.append(FieldPart(
          label: "\(known ?? "Unknown key"), \(fingerprint)",
          bytes: record.length,
          tint: .own,
          definition: definition
        ))
      }
      return Copy(
        name: "global_xpub",
        definition: "PSBT_GLOBAL_XPUB. The coordinator's claim about who the wallet's \(context.cosignersPhrase) are: one account-level extended public key per cosigner, with the master fingerprint and derivation path it came from.",
        extended: "A signing device can use these to trace each key in a script back to an account xpub and describe the wallet on its screen. But an air-gapped device has to assume the coordinator could be compromised, and a compromised coordinator can list any xpubs it likes. Tracing a key to one of these xpubs proves only that the xpub derives the key, not that it belongs to one of your cosigners. A device that trusted them could be shown a multisig that contains its own key alongside an attacker's keys and call it your wallet. The trustworthy source for the cosigner set is a wallet descriptor loaded onto the device beforehand, so these entries are informational at best. That is why Birch leaves them out of a compact PSBT. Each xpub is 78 bytes because that is the fixed BIP-32 serialization; the path is 4 bytes per level, and a BIP-48 account path (m/48h/coin/account/2h) has 4 levels.",
        partsLabel: "\(count) \(count == 1 ? "entry" : "entries"), one per claimed cosigner",
        parts: parts
      )
    case 0x02:
      return Copy(name: "tx_version", definition: "PSBT_GLOBAL_TX_VERSION. The transaction's 4-byte nVersion, carried as its own field in a version 2 PSBT instead of inside unsigned_tx.", isV2: true)
    case 0x03:
      return Copy(name: "fallback_locktime", definition: "PSBT_GLOBAL_FALLBACK_LOCKTIME. The 4-byte nLockTime to use when no input requires a specific one.", isV2: true)
    case 0x04:
      return Copy(name: "input_count", definition: "PSBT_GLOBAL_INPUT_COUNT. How many input maps follow, replacing the count inside unsigned_tx.", isV2: true)
    case 0x05:
      return Copy(name: "output_count", definition: "PSBT_GLOBAL_OUTPUT_COUNT. How many output maps follow, replacing the count inside unsigned_tx.", isV2: true)
    case 0x06:
      return Copy(name: "tx_modifiable", definition: "PSBT_GLOBAL_TX_MODIFIABLE. Flags saying whether inputs and outputs may still be added before signing is complete.", isV2: true)
    case 0xFB:
      let version = context.parsed.version
      return Copy(
        name: "version",
        definition: "PSBT_GLOBAL_VERSION. Tells every participant which PSBT format rules to parse the file with, so none of them misreads a field. This one says version \(version).",
        extended: "A 4-byte integer. Leaving it out means version 0, the original BIP-174 format that air-gapped signers expect. Version 2 (BIP-370) replaces unsigned_tx with separate per-field records. BIP-174 requires a parser to stop on a version it does not recognise rather than guess."
      )
    case 0xFC:
      return proprietaryCopy(mapPrefix: "GLOBAL")
    default:
      return unknownCopy(keyType: keyType)
    }
  }

  private static func unsignedTxParts(record: PSBTRecord, tx: PSBTUnsignedTx, context: Context) -> [FieldPart] {
    let envelope = record.length - record.value.count
    let valueLengthBytes = PSBTParser.compactSizeLength(record.value.count)
    var parts: [FieldPart] = [
      FieldPart(
        label: "key and length prefixes",
        bytes: envelope,
        tint: .global,
        definition: "A 1-byte key length, the 1-byte key type 0x00 (this key carries no key data), and a \(valueLengthBytes)-byte length for the \(record.value.count.formatted())-byte transaction. \(valueLengthBytes > 1 ? "Lengths of 253 bytes or more need the 3-byte compact size form." : "Lengths under 253 fit in a single byte.")"
      ),
      FieldPart(
        label: "nVersion",
        bytes: 4,
        tint: .global,
        definition: "A 4-byte signed integer, part of every signature's sighash. "
          + (tx.version >= 2
            ? "Version \(tx.version) enables BIP-68 relative locktimes."
            : "Version \(tx.version).")
      ),
      FieldPart(
        label: "input count",
        bytes: tx.inputCountLength,
        tint: .global,
        definition: "A compact size count of the inputs: \(tx.inputs.count)."
      ),
    ]

    let inputShape = "32-byte txid (a double SHA-256, so always 32 bytes), 4-byte output index, a 1-byte scriptSig length that must be 0x00 (a P2WSH input's signatures go in the witness, never the scriptSig), and a 4-byte sequence."
    if tx.inputs.count > 3 {
      let bytes = tx.inputs.reduce(0) { $0 + $1.length }
      let rbf = tx.inputs.allSatisfy { $0.sequence < 0xFFFF_FFFE }
      parts.append(FieldPart(
        label: "\(tx.inputs.count) × outpoint and sequence",
        bytes: bytes,
        tint: .input,
        definition: "Each is a \(inputShape) \(tx.inputs.count) of them are \(bytes.formatted()) bytes, the part of the transaction that grows with every coin spent.\(rbf ? " Every sequence is below 0xFFFFFFFE, which signals replace-by-fee." : "")"
      ))
    } else {
      for (i, input) in tx.inputs.enumerated() {
        var definition = i == 0 ? inputShape : "Same 41-byte shape."
        definition += " Spends output \(input.vout) with sequence 0x\(String(format: "%08X", input.sequence))"
        definition += input.sequence < 0xFFFF_FFFE ? ", which signals replace-by-fee." : "."
        parts.append(FieldPart(label: "in \(i): outpoint and sequence", bytes: input.length, tint: .input, definition: definition))
      }
    }

    parts.append(FieldPart(
      label: "output count",
      bytes: tx.outputCountLength,
      tint: .global,
      definition: "A compact size count of the outputs: \(tx.outputs.count)."
    ))

    for (i, output) in tx.outputs.enumerated() {
      let hasMap = !context.parsed.records(in: .output(i)).isEmpty
      let kind = scriptKind(output.script)
      var definition = "An 8-byte amount (\(output.amount.formatted()) sats), a 1-byte script length, and the \(output.script.count)-byte scriptPubKey. \(scriptShape(kind))"
      definition += hasMap
        ? " Output \(i)'s map below carries the coordinator's claim that this script belongs to the wallet."
        : " Nothing else about this output appears anywhere in the PSBT, so a device can only show the address for you to check."
      parts.append(FieldPart(label: "out \(i): amount and \(kind) script", bytes: output.length, tint: .output, definition: definition))
    }

    let lockDescription = tx.lockTime == 0
      ? "A 4-byte locktime of zero, so no locktime applies."
      : tx.lockTime < 500_000_000
      ? "A 4-byte locktime: block height \(tx.lockTime.formatted()). Setting it near the chain tip discourages fee sniping."
      : "A 4-byte locktime holding a Unix timestamp, \(tx.lockTime)."
    parts.append(FieldPart(label: "nLockTime", bytes: 4, tint: .global, definition: lockDescription))
    return parts
  }

  // MARK: - Input

  private static func inputCopy(keyType: UInt64, records: [PSBTRecord], context: Context) -> Copy {
    let record = records.first
    switch keyType {
    case 0x00:
      let share = context.parsed.totalBytes > 0 ? Double(records.reduce(0) { $0 + $1.length }) / Double(context.parsed.totalBytes) : 0
      var extended = "The only way a device can prove how much this input is worth. It hashes this transaction, checks the result is the txid in the input's outpoint, and reads the amount from the output that outpoint points to. witness_utxo alone cannot give that proof: BIP-143 commits each signature to its own input's amount only, so a compromised coordinator can understate a different input in each of two signing rounds and combine the valid signatures from both, hiding a large fee from the device. Its size is the entire parent transaction, which is why it is often the heaviest thing in the file; this one is \(share.formatted(.percent.precision(.fractionLength(0)))) of it."
      if context.compactDrops {
        extended += " Birch's compact PSBT drops it, leaving the device to rely on witness_utxo."
      }
      return Copy(
        name: "non_witness_utxo",
        definition: "PSBT_IN_NON_WITNESS_UTXO. The full previous transaction this input spends, so a signer can verify the input's amount and script for itself instead of taking the coordinator's word.",
        extended: extended
      )
    case 0x01:
      var amountText = "The value is an 8-byte amount, a 1-byte script length, and the scriptPubKey"
      if let value = record?.value, value.count >= 9 {
        let bytes = [UInt8](value)
        let amount = PSBTParser.readUInt64(bytes, 0)
        let script = Data(bytes[9...])
        amountText = "The value is an 8-byte amount (\(amount.formatted()) sats), a 1-byte script length, and the \(script.count)-byte scriptPubKey. \(scriptShape(scriptKind(script)))"
      }
      return Copy(
        name: "witness_utxo",
        definition: "PSBT_IN_WITNESS_UTXO. The amount and scriptPubKey of the output this input spends: the two facts a signer needs to compute a P2WSH sighash and to work out the fee.",
        extended: "BIP-143 commits a segwit signature to the amount of the input being signed, so the device cannot sign without that amount, and the fee is the inputs' total minus the outputs' total. As supplied, this field is still the coordinator's claim. A wrong amount makes this input's signature invalid, but it cannot stop a compromised coordinator from understating different inputs across separate signing rounds; only non_witness_utxo proves the amount. If a PSBT leaves witness_utxo out, a signer can derive it from non_witness_utxo: hash that transaction's non-witness serialization, confirm the result is the txid in this input's outpoint, then take the output at the outpoint's index. Its amount and scriptPubKey are exactly this field's contents, and derived that way they are proven rather than claimed. \(context.compactDrops ? "Birch's compact QR drops non_witness_utxo, so a device scanning it has only this field to go on. " : "")\(amountText)",
        requiredToSign: true
      )
    case 0x02:
      return partialSigCopy(records: records, context: context)
    case 0x03:
      var flagText = ""
      if let value = record?.value, value.count == 4 {
        let flag = PSBTParser.readUInt32([UInt8](value), 0)
        flagText = " Here it is \(flag), \(PSBTParser.sighashName(flag))."
      }
      return Copy(
        name: "sighash_type",
        definition: "PSBT_IN_SIGHASH_TYPE. Tells every cosigner which parts of the transaction their signature on this input must commit to, so all of their signatures agree.\(flagText)",
        extended: "SIGHASH_ALL commits to every input and every output, so once signed, nobody can add, remove or redirect anything. The other flags leave parts of the transaction uncommitted; SIGHASH_NONE, for example, signs no outputs at all. The coordinator chooses this value, so a careful device refuses anything other than SIGHASH_ALL, and Birch flags it as critical. The value is 4 bytes because the sighash preimage serializes the type as a 4-byte integer; only its low byte is appended to each signature."
      )
    case 0x04:
      return Copy(
        name: "redeem_script",
        definition: "PSBT_IN_REDEEM_SCRIPT. The script a P2SH output commits to by hash.",
        extended: "Native P2WSH inputs do not use one; the script lives in witness_script. Seeing this field means the input is P2SH-wrapped or legacy, which Birch wallets do not create.",
        requiredToSign: true
      )
    case 0x05:
      let summary = record.flatMap { PSBTParser.multisigSummary($0.value) }
      let definition = summary.map { "PSBT_IN_WITNESS_SCRIPT. The \($0.m)-of-\($0.n) spending conditions this input is locked to. The input's scriptPubKey holds only its SHA-256 hash, so a signer needs the script itself to sign and the finalizer needs it to build the witness." }
        ?? "PSBT_IN_WITNESS_SCRIPT. The spending conditions this input is locked to. The input's scriptPubKey holds only its SHA-256 hash, so a signer needs the script itself to sign and the finalizer needs it to build the witness."
      var extended = ""
      if let summary, let record {
        extended = "OP_\(summary.m), then \(summary.n) × (a 1-byte push and a 33-byte compressed pubkey), then OP_\(summary.n) and OP_CHECKMULTISIG: 3 + 34 × \(summary.n) = \(record.value.count) bytes. With sortedmulti the keys are in lexicographic order, so every coordinator builds the same script from the same keys. "
      }
      extended += "A device hashes the script and checks it matches the input's P2WSH scriptPubKey. BIP-143 also commits every signature to this exact script, so a signature made over a substituted script is useless. What the hash cannot prove is that the other keys belong to your cosigners; for that, the device compares the keys against its own trusted wallet descriptor."
      return Copy(
        name: "witness_script",
        definition: definition,
        extended: extended,
        requiredToSign: true
      )
    case 0x06:
      return derivationCopy(
        name: "bip32_derivation",
        constant: "PSBT_IN_BIP32_DERIVATION",
        keyTypeLabel: "0x06",
        records: records,
        definition: "Tells each signing device which of the input's keys is its own and where to find it: each pubkey in the witness script, with the master fingerprint and full derivation path claimed to produce it.",
        extendedTail: "A device looks for its own fingerprint, re-derives the key at the claimed path from its seed, and signs only if the derived key is exactly the pubkey listed and appears in the witness script. The fingerprint is just a routing hint the coordinator wrote. A false claim on an input makes it unsignable rather than dangerous, because a key the device does not hold cannot spend it.",
        context: context
      )
    case 0x07:
      return Copy(
        name: "final_scriptsig",
        definition: "PSBT_IN_FINAL_SCRIPTSIG. The completed scriptSig, written by the finalizer.",
        extended: "A native P2WSH input's scriptSig is always empty; its signatures go in final_scriptwitness. Seeing this field on a Birch input means the input is P2SH-wrapped or legacy."
      )
    case 0x08:
      let m = context.requiredSignatures.map { "the \($0) signatures" } ?? "the signatures"
      return Copy(
        name: "final_scriptwitness",
        definition: "PSBT_IN_FINAL_SCRIPTWITNESS. The finished witness stack that proves this input may be spent. It is what actually reaches the network.",
        extended: "Built by the finalizer (Birch, through BDK), not by a signing device, once enough partial signatures are in. For P2WSH multisig the stack is an empty item (OP_CHECKMULTISIG pops one more item than it uses), then \(m) in the same order as their keys appear in the witness script, then the witness script itself. Its size follows from that: an item count, 1 byte for the empty item, about 72 to 74 bytes per signature with its length, and the witness script with its length prefix. BIP-174 then has the finalizer clear the signatures, scripts and derivations from the input, since the finished witness supersedes them."
      )
    case 0x09:
      return Copy(name: "por_commitment", definition: "PSBT_IN_POR_COMMITMENT. A proof-of-reserves commitment string.")
    case 0x0A:
      return Copy(name: "ripemd160", definition: "PSBT_IN_RIPEMD160. A hash preimage a script on this input needs.")
    case 0x0B:
      return Copy(name: "sha256", definition: "PSBT_IN_SHA256. A hash preimage a script on this input needs.")
    case 0x0C:
      return Copy(name: "hash160", definition: "PSBT_IN_HASH160. A hash preimage a script on this input needs.")
    case 0x0D:
      return Copy(name: "hash256", definition: "PSBT_IN_HASH256. A hash preimage a script on this input needs.")
    case 0x0E:
      return Copy(name: "previous_txid", definition: "PSBT_IN_PREVIOUS_TXID. The 32-byte txid of the transaction this input spends from.", isV2: true)
    case 0x0F:
      return Copy(name: "output_index", definition: "PSBT_IN_OUTPUT_INDEX. The 4-byte index of the output being spent.", isV2: true)
    case 0x10:
      return Copy(name: "sequence", definition: "PSBT_IN_SEQUENCE. The input's 4-byte nSequence. When absent it is 0xFFFFFFFF.", isV2: true)
    case 0x11:
      return Copy(name: "required_time_locktime", definition: "PSBT_IN_REQUIRED_TIME_LOCKTIME. The minimum time-based locktime this input needs.", isV2: true)
    case 0x12:
      return Copy(name: "required_height_locktime", definition: "PSBT_IN_REQUIRED_HEIGHT_LOCKTIME. The minimum height-based locktime this input needs.", isV2: true)
    case 0x13:
      return Copy(name: "tap_key_sig", definition: "PSBT_IN_TAP_KEY_SIG. A Schnorr signature for a taproot key-path spend. Not used by P2WSH.")
    case 0x14:
      return Copy(name: "tap_script_sig", definition: "PSBT_IN_TAP_SCRIPT_SIG. A Schnorr signature for a taproot script-path spend. Not used by P2WSH.")
    case 0x15:
      return Copy(name: "tap_leaf_script", definition: "PSBT_IN_TAP_LEAF_SCRIPT. A taproot leaf script and its control block. Not used by P2WSH.")
    case 0x16:
      return Copy(name: "tap_bip32_derivation", definition: "PSBT_IN_TAP_BIP32_DERIVATION. Fingerprints and paths for taproot x-only keys. Not used by P2WSH.")
    case 0x17:
      return Copy(name: "tap_internal_key", definition: "PSBT_IN_TAP_INTERNAL_KEY. The taproot internal key before tweaking. Not used by P2WSH.")
    case 0x18:
      return Copy(name: "tap_merkle_root", definition: "PSBT_IN_TAP_MERKLE_ROOT. The root of a taproot script tree. Not used by P2WSH.")
    case 0x1A:
      return Copy(name: "musig2_participant_pubkeys", definition: "PSBT_IN_MUSIG2_PARTICIPANT_PUBKEYS. The keys behind a MuSig2 aggregate key. Not used by P2WSH.")
    case 0x1B:
      return Copy(name: "musig2_pub_nonce", definition: "PSBT_IN_MUSIG2_PUB_NONCE. A MuSig2 participant's public nonce. Not used by P2WSH.")
    case 0x1C:
      return Copy(name: "musig2_partial_sig", definition: "PSBT_IN_MUSIG2_PARTIAL_SIG. A MuSig2 participant's partial signature. Not used by P2WSH.")
    case 0xFC:
      return proprietaryCopy(mapPrefix: "IN")
    default:
      return unknownCopy(keyType: keyType)
    }
  }

  private static func partialSigCopy(records: [PSBTRecord], context: Context) -> Copy {
    guard let first = records.first, case let .input(inputIndex) = first.map else {
      return Copy(name: "partial_sig", definition: "PSBT_IN_PARTIAL_SIG. A cosigner's signature for this input, returned by its signing device.")
    }
    let (counted, foreign) = context.parsed.partialSignatures(input: inputIndex)
    let foreignKeys = Set(foreign.map(\.keyData))
    let k = counted.count
    let inputRecords = context.parsed.records(in: first.map)
    let derivations = inputRecords.filter { $0.keyType == 0x06 }
    let thresholdMet = context.requiredSignatures.map { k >= $0 } ?? false

    var parts: [FieldPart] = []
    var covered = Set<Data>()
    for derivation in derivations {
      let fingerprint = PSBTParser.derivation(from: derivation.value)?.fingerprint ?? "????????"
      let name = context.cosignerLabel(for: fingerprint) ?? "Unknown key"
      covered.insert(derivation.keyData)
      if let sig = records.first(where: { $0.keyData == derivation.keyData }) {
        let isForeign = foreignKeys.contains(sig.keyData)
        parts.append(FieldPart(
          label: "\(name), \(fingerprint)\(isForeign ? ", not in script" : "")",
          bytes: sig.length,
          tint: .own,
          definition: signatureDefinition(sig) + (isForeign ? foreignNote : "")
        ))
      } else {
        parts.append(FieldPart(
          label: "\(name), \(fingerprint)",
          bytes: 0,
          tint: .absent,
          definition: thresholdMet
            ? "Has not signed. The threshold is already met, so this key is not needed. Birch holds no private keys, so a signature can only come from this cosigner's device."
            : "Has not signed yet. Birch holds no private keys, so a signature can only come from this cosigner's device."
        ))
      }
    }
    for sig in records where !covered.contains(sig.keyData) {
      let isForeign = foreignKeys.contains(sig.keyData)
      parts.append(FieldPart(
        label: isForeign ? "Unknown key, not in script" : "Unknown key",
        bytes: sig.length,
        tint: .own,
        definition: signatureDefinition(sig) + " No bip32_derivation on this input names this pubkey." + (isForeign ? foreignNote : "")
      ))
    }

    let n = context.totalKeys ?? max(derivations.count, k)
    var progress = "\(k) of \(n) keys have signed this input"
    if let m = context.requiredSignatures {
      progress += k >= m ? ", which meets the threshold of \(m)." : ". It needs \(m)."
    } else {
      progress += "."
    }
    if !foreign.isEmpty {
      progress += " \(foreign.count) more \(foreign.count == 1 ? "signature is" : "signatures are") from a key outside this input's witness script and cannot count."
    }

    return Copy(
      name: "partial_sig",
      definition: "PSBT_IN_PARTIAL_SIG. A cosigner's signature on this input, returned by its air-gapped signing device, keyed by the pubkey that made it. \(progress)",
      extended: "Each signature commits to the BIP-143 sighash for this input: the unsigned transaction's version, outpoints, sequences, outputs and locktime, together with this input's own amount and witness script. Keying each record by pubkey lets devices sign in separate rounds; Birch merges the returned PSBTs by taking the union, and no device can overwrite another's signature. Every input needs its own threshold of signatures. Birch counts a signature only when its pubkey is one of the keys in this input's witness script, and flags any signature that is not SIGHASH_ALL. The key is 34 bytes (the type byte and a 33-byte compressed pubkey); the value is a DER-encoded signature of about 70 to 72 bytes plus a 1-byte sighash flag. DER varies by a byte or two because it encodes r and s as minimal-length integers.",
      partsLabel: "\(k) of \(n) keys have signed",
      parts: parts.isEmpty ? nil : parts
    )
  }

  private static let foreignNote = " This pubkey is not one of the keys in this input's witness script, or the script does not match the output being spent, so the signature cannot count toward the threshold. Birch refuses to import a PSBT carrying one."

  private static func signatureDefinition(_ sig: PSBTRecord) -> String {
    let flag = sig.value.last.map { PSBTParser.sighashName(UInt32($0)) } ?? "sighash"
    return "\(sig.length) bytes: a length byte, the type byte 0x02, and the \(sig.keyData.count)-byte pubkey identifying the cosigner; then a length byte, a \(max(sig.value.count - 1, 0))-byte DER signature, and the 1-byte \(flag) flag."
  }

  private static func derivationCopy(
    name: String,
    constant: String,
    keyTypeLabel: String,
    records: [PSBTRecord],
    definition: String,
    extendedTail: String,
    forOutput: Bool = false,
    context _: Context
  ) -> Copy {
    guard let first = records.first else {
      return Copy(name: name, definition: "\(constant). \(definition)")
    }
    let decoded = PSBTParser.derivation(from: first.value)
    let path = decoded?.path ?? "an unreadable path"
    let levels = decoded?.levels ?? 0
    // Every part is labelled with exactly the bytes it counts, and together they
    // sum to one record's serialized length
    let prefixBytes = first.keyLengthPrefix + first.valueLengthPrefix
    let keyTypeBytes = first.length - prefixBytes - first.keyData.count - first.value.count
    let fingerprintBytes = min(4, first.value.count)
    let pathBytes = max(first.value.count - 4, 0)

    let parts = [
      FieldPart(
        label: "key and value length prefixes",
        bytes: prefixBytes,
        tint: .own,
        definition: "A compact size length in front of the key and another in front of the value. Framing only, no content."
      ),
      FieldPart(
        label: "key type \(keyTypeLabel)",
        bytes: keyTypeBytes,
        tint: .own,
        definition: "Marks the record as a BIP-32 derivation."
      ),
      FieldPart(
        label: "key: \(first.keyData.count)-byte pubkey",
        bytes: first.keyData.count,
        tint: .own,
        definition: "The compressed public key: a 1-byte prefix (0x02 or 0x03, the parity of y) and the 32-byte x coordinate. Putting the pubkey in the key lets \(records.count) entries sit in one map, one per key in the witness script."
      ),
      FieldPart(
        label: "value: 4-byte fingerprint",
        bytes: fingerprintBytes,
        tint: .own,
        definition: "The first 4 bytes of the HASH160 of the claimed master public key. Short enough to collide and chosen by the coordinator, so a device treats it as a hint for finding its own entry, never as proof of ownership."
      ),
      FieldPart(
        label: "value: \(levels) path levels, \(pathBytes) bytes",
        bytes: pathBytes,
        tint: .own,
        definition: "\(path): \(levels) × 4-byte little-endian integers, with hardened levels at 2³¹ and above. A BIP-48 multisig path has 6 levels (purpose, coin, account, script type 2h for P2WSH, then 0 for receive or 1 for change, then the address index). The device re-derives the key along this path from its own seed and compares the result with the pubkey above."
      ),
    ]

    return Copy(
      name: name,
      definition: "\(constant). \(definition)",
      extended: "One entry per pubkey in the witness script, \(path) for the first key here. \(extendedTail)",
      partsLabel: "Anatomy of one entry, ×\(records.count) keys",
      parts: parts,
      // An input's derivations tell the device which key to sign with; an output's
      // only let it check the output is change
      requiredToSign: !forOutput,
      verifiesChange: forOutput
    )
  }

  // MARK: - Output

  private static func outputCopy(keyType: UInt64, records: [PSBTRecord], context: Context) -> Copy {
    let record = records.first
    switch keyType {
    case 0x00:
      return Copy(
        name: "redeem_script",
        definition: "PSBT_OUT_REDEEM_SCRIPT. The script a P2SH output commits to by hash.",
        extended: "Native P2WSH change uses witness_script instead. Seeing this field means the output is P2SH-wrapped or legacy, which Birch wallets do not create.",
        verifiesChange: true
      )
    case 0x01:
      let summary = record.flatMap { PSBTParser.multisigSummary($0.value) }
      var extended = "Output \(outputIndex(records)) pays a P2WSH scriptPubKey that holds only the SHA-256 hash of its script. Given the script, a device hashes it, rebuilds the scriptPubKey, and compares it byte for byte with the output in unsigned_tx. It then checks that its own key, re-derived from its seed, is one of the script's keys. A mismatch in either check means the coordinator lied about this output. Passing both proves the output pays a multisig that includes the device, but not that the other keys are your cosigners. Only a wallet descriptor already trusted by the device can confirm that, and without that check an attacker could route \"change\" to a multisig they control."
      if let summary, let record {
        extended += " The script is 3 + 34 × \(summary.n) = \(record.value.count) bytes: OP_\(summary.m), \(summary.n) pushed 33-byte pubkeys, OP_\(summary.n), OP_CHECKMULTISIG."
      }
      return Copy(
        name: "witness_script",
        definition: summary.map { "PSBT_OUT_WITNESS_SCRIPT. The \($0.m)-of-\($0.n) script this output claims to be locked to, so a signing device can check for itself that the output really comes back to the wallet instead of trusting the coordinator." }
          ?? "PSBT_OUT_WITNESS_SCRIPT. The script this output claims to be locked to, so a signing device can check for itself that the output really comes back to the wallet instead of trusting the coordinator.",
        extended: extended,
        verifiesChange: true
      )
    case 0x02:
      return derivationCopy(
        name: "bip32_derivation",
        constant: "PSBT_OUT_BIP32_DERIVATION",
        keyTypeLabel: "0x02",
        records: records,
        definition: "The coordinator's claim that this output is change: the fingerprint and derivation path behind each pubkey in the output's witness script.",
        extendedTail: "A device uses these claims to test the output, not to believe it. It re-derives its own key at the claimed path and checks that key is in the \(context.policy) witness script whose hash this output pays. If the claim names the device's fingerprint but the key does not derive, or the script contradicts the scriptPubKey, the PSBT is lying about where money goes and should be rejected. A change index (a 1 in the second-to-last level) tells a device to show the output as change rather than a receive address. Leave these out and a careful device shows your own change as an outside payment.",
        forOutput: true,
        context: context
      )
    case 0x03:
      return Copy(name: "amount", definition: "PSBT_OUT_AMOUNT. The output's 8-byte value in sats, carried as its own field in a version 2 PSBT.", isV2: true)
    case 0x04:
      return Copy(name: "script", definition: "PSBT_OUT_SCRIPT. The output's scriptPubKey, carried as its own field in a version 2 PSBT.", isV2: true)
    case 0x05:
      return Copy(name: "tap_internal_key", definition: "PSBT_OUT_TAP_INTERNAL_KEY. The taproot internal key behind this output. Not used by P2WSH.")
    case 0x06:
      return Copy(name: "tap_tree", definition: "PSBT_OUT_TAP_TREE. The taproot script tree behind this output. Not used by P2WSH.")
    case 0x07:
      return Copy(name: "tap_bip32_derivation", definition: "PSBT_OUT_TAP_BIP32_DERIVATION. Fingerprints and paths for this output's taproot keys. Not used by P2WSH.")
    case 0x08:
      return Copy(name: "musig2_participant_pubkeys", definition: "PSBT_OUT_MUSIG2_PARTICIPANT_PUBKEYS. The keys behind a MuSig2 aggregate key. Not used by P2WSH.")
    case 0x09:
      return Copy(name: "dnssec_proof", definition: "PSBT_OUT_DNSSEC_PROOF. A DNSSEC proof for a BIP-353 human-readable payment name.")
    case 0xFC:
      return proprietaryCopy(mapPrefix: "OUT")
    default:
      return unknownCopy(keyType: keyType)
    }
  }

  private static func outputIndex(_ records: [PSBTRecord]) -> String {
    if case let .output(i)? = records.first?.map {
      return "\(i)"
    }
    return ""
  }

  static func emptySectionNote(location: PSBTMapLocation, context: Context) -> String? {
    guard case let .output(i) = location else {
      return "This map is empty."
    }
    guard let tx = context.parsed.unsignedTx, i < tx.outputs.count else {
      return "This map is empty."
    }
    let output = tx.outputs[i]
    return "A payment to an outside address: \(output.amount.formatted()) sats. The coordinator makes no claim that it belongs to the wallet, so the map is empty, and a signing device can only show you the address and amount to confirm on its screen. The \(output.length) bytes that define it (8-byte amount, script length, \(output.script.count)-byte scriptPubKey) live inside the global unsigned_tx."
  }

  // MARK: - Generic

  private static func proprietaryCopy(mapPrefix: String) -> Copy {
    Copy(
      name: "proprietary",
      definition: "PSBT_\(mapPrefix)_PROPRIETARY. Application-specific data whose key starts with an identifier chosen by whichever software wrote it.",
      extended: "Birch does not interpret it. BIP-174 requires every participant to pass records like this through unchanged, so the software that added it can find it again. It is shown here so a device's behaviour can be debugged.",
      isUnrecognized: true
    )
  }

  private static func unknownCopy(keyType: UInt64) -> Copy {
    Copy(
      name: "unknown \(String(format: "0x%02llX", keyType))",
      definition: "A key type Birch does not recognise.",
      extended: "BIP-174 requires every participant to pass unknown records through unchanged, so whichever wallet or signer added it expects it to survive the round trip. It is shown here rather than hidden so a device's behaviour can be debugged.",
      isUnrecognized: true
    )
  }

  /// Why a scriptPubKey of this kind is the size it is
  private static func scriptShape(_ kind: String) -> String {
    switch kind {
    case "P2WSH": "A P2WSH scriptPubKey is OP_0, a push of 32, and the 32-byte SHA-256 of the witness script: 34 bytes."
    case "P2WPKH": "A P2WPKH scriptPubKey is OP_0, a push of 20, and the 20-byte HASH160 of a public key: 22 bytes."
    case "P2TR": "A P2TR scriptPubKey is OP_1, a push of 32, and a 32-byte tweaked public key: 34 bytes."
    case "P2SH": "A P2SH scriptPubKey is OP_HASH160, a 20-byte script hash, and OP_EQUAL: 23 bytes."
    case "P2PKH": "A P2PKH scriptPubKey wraps a 20-byte public key hash in five opcodes: 25 bytes."
    default: "A non-standard or data-carrying script."
    }
  }

  static func scriptKind(_ script: Data) -> String {
    let bytes = [UInt8](script)
    switch (bytes.count, bytes.first) {
    case (34, 0x00) where bytes[1] == 0x20: return "P2WSH"
    case (22, 0x00) where bytes[1] == 0x14: return "P2WPKH"
    case (34, 0x51) where bytes[1] == 0x20: return "P2TR"
    case (23, 0xA9): return "P2SH"
    case (25, 0x76): return "P2PKH"
    default: return "output"
    }
  }
}

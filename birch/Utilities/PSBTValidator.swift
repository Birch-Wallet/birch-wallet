import BitcoinDevKit
import CryptoKit
import Foundation

// MARK: - Finding

/// A single problem found while checking a PSBT against what the wallet itself knows.
///
/// Findings are returned rather than thrown so each call site can choose its own
/// policy: the import path refuses on anything critical, while a display surface
/// can show warnings without blocking.
struct PSBTFinding: Equatable {
  enum Severity {
    /// The PSBT contradicts wallet state. Block the operation.
    case critical
    /// The claim could not be checked either way. Surface it, but do not block.
    case warning
    case info
  }

  /// Stable identifiers so call sites and tests never repeat raw strings.
  enum Code {
    static let inputAmountMismatch = "input.amount_mismatch"
    static let inputUtxoDisagreement = "input.utxo_disagreement"
    static let inputPrevTxidMismatch = "input.prevtx_txid_mismatch"
    static let inputPrevoutOutOfRange = "input.prevout_out_of_range"
    static let inputMissingUtxo = "input.missing_utxo"
    static let inputAmountUnverifiable = "input.amount_unverifiable"
    static let inputCountMismatch = "input.count_mismatch"
    static let psbtUnparseable = "psbt.unparseable"
    static let psbtUnextractable = "psbt.unextractable"
    static let outputDerivationDepth = "output.derivation_depth"
    static let outputDerivationOrigin = "output.derivation_origin"
    static let outputDerivationChain = "output.derivation_chain"
    static let outputDerivationHardenedIndex = "output.derivation_hardened_index"
    static let outputDerivationDisagreement = "output.derivation_disagreement"
    static let outputDerivationScriptMismatch = "output.derivation_script_mismatch"
    static let outputUnknownFingerprint = "output.unknown_fingerprint"
    static let outputBeyondGapLimit = "output.beyond_gap_limit"
    static let inputWitnessScriptMismatch = "input.witness_script_mismatch"
    static let inputForeignSignature = "input.foreign_signature"
    static let inputNonDefaultSighash = "input.non_default_sighash"
    static let inputMalformedSignature = "input.malformed_signature"
  }

  let severity: Severity
  let code: String
  /// "txid:vout" when the finding is scoped to a single input.
  let outpoint: String?
  /// User-facing explanation. Shown verbatim in error alerts.
  let message: String

  static func critical(_ code: String, outpoint: String? = nil, _ message: String) -> PSBTFinding {
    PSBTFinding(severity: .critical, code: code, outpoint: outpoint, message: message)
  }

  static func warning(_ code: String, outpoint: String? = nil, _ message: String) -> PSBTFinding {
    PSBTFinding(severity: .warning, code: code, outpoint: outpoint, message: message)
  }
}

extension [PSBTFinding] {
  var criticals: [PSBTFinding] {
    filter { $0.severity == .critical }
  }

  var warnings: [PSBTFinding] {
    filter { $0.severity == .warning }
  }

  var hasCritical: Bool {
    contains { $0.severity == .critical }
  }
}

// MARK: - Verification State

/// UI-facing summary of one verification pass, so views never re-derive severity
/// from raw findings.
enum PSBTVerificationState: Equatable {
  /// Nothing has been verified for the current PSBT bytes yet.
  case notChecked
  /// Every input's declared amount matched the wallet's own record.
  case verified(inputs: Int)
  /// Nothing contradicted wallet state, but some inputs could not be checked —
  /// an unsynced wallet, or inputs this wallet has no record of.
  case partiallyVerified(verified: Int, unverified: Int)
  /// A check contradicted wallet state. Carries the finding's message.
  case failed(String)

  /// - Parameter inputCount: number of inputs in the PSBT being described.
  init(findings: [PSBTFinding], inputCount: Int) {
    if let critical = findings.criticals.first {
      self = .failed(critical.message)
    } else if findings.warnings.isEmpty {
      self = .verified(inputs: inputCount)
    } else {
      // Every warning code today is a per-input "could not verify".
      let unverified = min(findings.warnings.count, inputCount)
      self = .partiallyVerified(verified: max(inputCount - unverified, 0), unverified: unverified)
    }
  }
}

// MARK: - Ground Truth

/// What the wallet knows independently of the PSBT being checked.
///
/// Kept deliberately minimal — add a field when a check needs it, not before.
struct PSBTGroundTruth {
  /// "txid:vout" → amount in sats, from the wallet's own synced state.
  /// A missing entry means "cannot verify", never "wrong".
  let knownOutputAmounts: [String: UInt64]

  /// The BIP-48 account origin every key of this wallet sits under, as path
  /// components with the hardened bit set — 48'/coinType'/0'/2'. Empty disables
  /// derivation checking.
  let accountOrigin: [UInt32]

  /// Master fingerprints of this wallet's cosigners, lowercased.
  let cosignerFingerprints: Set<String>

  /// Derives the script this wallet would produce at a keychain and index. This is
  /// what makes a claimed derivation path checkable rather than merely plausible;
  /// nil when no wallet is available to ask.
  let scriptAt: (KeychainKind, UInt32) -> Script?

  init(
    knownOutputAmounts: [String: UInt64],
    accountOrigin: [UInt32] = [],
    cosignerFingerprints: Set<String> = [],
    scriptAt: @escaping (KeychainKind, UInt32) -> Script? = { _, _ in nil }
  ) {
    self.knownOutputAmounts = knownOutputAmounts
    self.accountOrigin = accountOrigin
    // Fingerprints reach us from user entry, descriptors, and PSBTs; normalise once
    // here so no comparison has to remember to.
    self.cosignerFingerprints = Set(cosignerFingerprints.map(CosignerInfo.normalizedFingerprint))
    self.scriptAt = scriptAt
  }

  /// The account origin Birch pins every descriptor to.
  ///
  /// Safe to hardcode because the app admits no other shape: `buildDescriptor` writes
  /// exactly this origin, and every way a wallet can be created — setup wizard,
  /// descriptor import, cosigner editing — runs
  /// `SetupWizardViewModel.validateDerivationPath`, which requires BIP-48, account 0,
  /// and a coin type matching the network. Widen account support and this must widen
  /// with it, or every change output will be reported as off-policy.
  static func accountOrigin(for network: BitcoinNetwork) -> [UInt32] {
    let hardened: UInt32 = 0x8000_0000
    return [48 | hardened, UInt32(network.coinType) | hardened, 0 | hardened, 2 | hardened]
  }

  /// Build ground truth from the wallet's cached view of its own history.
  ///
  /// Both sources are needed. `utxos` alone would leave every RBF bump PSBT
  /// unverifiable, because a bump spends the inputs of the original unconfirmed
  /// transaction and those outputs are no longer unspent — the same case
  /// `BitcoinService.pruneStaleeSavedPSBTs` carves out. Transaction outputs are
  /// stored in vout order, so their offsets are the vouts.
  static func from(
    utxos: [UTXOItem],
    transactions: [TransactionItem],
    network: BitcoinNetwork,
    cosignerFingerprints: Set<String> = [],
    scriptAt: @escaping (KeychainKind, UInt32) -> Script? = { _, _ in nil }
  ) -> PSBTGroundTruth {
    var amounts = Dictionary(uniqueKeysWithValues: utxos.map { ($0.id, $0.amount) })
    for tx in transactions {
      for (vout, output) in tx.outputs.enumerated() {
        amounts["\(tx.id):\(vout)"] = output.amount
      }
    }
    return PSBTGroundTruth(
      knownOutputAmounts: amounts,
      accountOrigin: accountOrigin(for: network),
      cosignerFingerprints: cosignerFingerprints,
      scriptAt: scriptAt
    )
  }
}

// MARK: - Output Classification

/// One output of a PSBT's transaction, described using the wallet's own knowledge
/// rather than anything the PSBT claims about itself.
struct PSBTOutputInfo: Equatable {
  enum Role: Equatable {
    /// Derived from the wallet's internal keychain — change coming back to us.
    case change
    /// One of the wallet's own receive addresses: a self-transfer, not change.
    case selfTransfer
    /// Not this wallet's script.
    case external
  }

  let index: Int
  let address: String
  let amount: UInt64
  let role: Role

  var isMine: Bool { role != .external }
}

// MARK: - Validator

/// Stateless checks that a PSBT's self-description matches reality.
///
/// Deliberately free of `BitcoinService`, `@MainActor`, and SwiftData: everything
/// the checks need arrives as parameters, which is what keeps them unit-testable
/// and reusable from any call site.
enum PSBTValidator {
  private typealias Code = PSBTFinding.Code

  /// Cross-check every input's declared amount against the wallet's own record.
  ///
  /// A PSBT states what its inputs are worth via `witness_utxo` / `non_witness_utxo`,
  /// and every fee figure derives from those numbers — BDK's `Psbt.fee()` simply sums
  /// them, and does not even check that an embedded previous transaction hashes to the
  /// outpoint being spent. A PSBT that under-declares an input therefore shows a
  /// believable but understated fee. These checks make the wallet's own view
  /// authoritative wherever it has one.
  ///
  /// - Parameter tx: the transaction from `psbt.extractTx()`. `Psbt` exposes no
  ///   accessor for its unsigned transaction, so the caller supplies it.
  static func verifyInputAmounts(
    psbt: Psbt,
    tx: Transaction,
    against truth: PSBTGroundTruth
  ) -> [PSBTFinding] {
    let psbtInputs = psbt.input()
    let txInputs = tx.input()

    guard psbtInputs.count == txInputs.count else {
      return [.critical(
        Code.inputCountMismatch,
        "PSBT carries \(psbtInputs.count) input records but its transaction spends \(txInputs.count) inputs"
      )]
    }

    return txInputs.enumerated().compactMap { index, txIn in
      let outpoint = "\(txIn.previousOutput.txid.description):\(txIn.previousOutput.vout)"
      return verify(
        input: psbtInputs[index],
        txIn: txIn,
        outpoint: outpoint,
        known: truth.knownOutputAmounts[outpoint]
      )
    }
  }

  /// The pubkeys that provably take part in spending an input.
  ///
  /// A P2WSH output commits to its witness script by hash, so a witness script that
  /// hashes to the spent output's script pubkey can be trusted even though the PSBT
  /// supplied it — and the keys inside it are then the only keys that can ever sign
  /// this input. Everything else a PSBT says about keys is just an assertion.
  ///
  /// - Returns: the verified key set, or nil when the input is not a P2WSH spend this
  ///   function can check (no witness script, or an unexpected script type).
  static func verifiedPubkeys(input: Input, txIn: TxIn) -> Set<String>? {
    guard let witnessScript = input.witnessScript,
          let spentScript = spentScriptPubkey(input: input, txIn: txIn)
    else { return nil }

    // P2WSH: OP_0 PUSH32 <sha256(witnessScript)>
    let spent = [UInt8](spentScript.toBytes())
    guard spent.count == 34, spent[0] == 0x00, spent[1] == 0x20 else { return nil }

    let scriptBytes = [UInt8](witnessScript.toBytes())
    let digest = Data(SHA256.hash(data: Data(scriptBytes)))
    guard digest == Data(spent[2...]) else { return [] } // committed hash disagrees

    return Set(compressedPubkeys(in: scriptBytes))
  }

  /// The script pubkey of the output an input spends, from whichever UTXO record the
  /// PSBT carries. Amount checks validate these records separately.
  private static func spentScriptPubkey(input: Input, txIn: TxIn) -> Script? {
    if let witnessUtxo = input.witnessUtxo { return witnessUtxo.scriptPubkey }
    guard let previousTx = input.nonWitnessUtxo else { return nil }
    let outputs = previousTx.output()
    let vout = Int(txIn.previousOutput.vout)
    guard vout < outputs.count else { return nil }
    return outputs[vout].scriptPubkey
  }

  /// Pull compressed pubkeys out of a script by scanning for 33-byte pushes. Enough
  /// for the `sortedmulti` scripts this wallet builds, and it does not care where in
  /// the script they sit.
  private static func compressedPubkeys(in script: [UInt8]) -> [String] {
    var keys: [String] = []
    var index = 0
    while index < script.count {
      let opcode = script[index]
      guard opcode == 0x21, index + 34 <= script.count else {
        index += 1
        continue
      }
      let key = Array(script[(index + 1) ... (index + 33)])
      if key[0] == 0x02 || key[0] == 0x03 {
        keys.append(key.map { String(format: "%02x", $0) }.joined())
      }
      index += 34
    }
    return keys
  }

  /// Check the signatures a PSBT carries: that they belong to keys which can actually
  /// sign each input, and that they commit to the whole transaction.
  static func verifySignatures(psbt: Psbt, tx: Transaction) -> [PSBTFinding] {
    let inputs = psbt.input()
    let txInputs = tx.input()
    guard inputs.count == txInputs.count else { return [] } // reported by the amount checks

    var findings: [PSBTFinding] = []

    for (index, input) in inputs.enumerated() {
      let outpoint = "\(txInputs[index].previousOutput.txid.description):\(txInputs[index].previousOutput.vout)"
      let verified = verifiedPubkeys(input: input, txIn: txInputs[index])

      if let verified, verified.isEmpty {
        findings.append(.critical(
          Code.inputWitnessScriptMismatch,
          outpoint: outpoint,
          "Input \(outpoint) carries a witness script that does not match the output being spent. The script that governs this input is not the one in this PSBT."
        ))
        continue
      }

      for (pubkey, signature) in input.partialSigs {
        if let verified, !verified.contains(pubkey.lowercased()) {
          findings.append(.critical(
            Code.inputForeignSignature,
            outpoint: outpoint,
            "Input \(outpoint) carries a signature from a key that is not part of the script securing it. It cannot contribute to spending this input."
          ))
          continue
        }

        if let finding = verifySighash(of: signature, pubkey: pubkey, outpoint: outpoint) {
          findings.append(finding)
        }
      }

      if let declared = input.sighashType,
         declared.replacingOccurrences(of: "_", with: "").caseInsensitiveCompare("SIGHASHALL") != .orderedSame
      {
        findings.append(.critical(
          Code.inputNonDefaultSighash,
          outpoint: outpoint,
          "Input \(outpoint) asks signers to use \(declared) rather than SIGHASH_ALL. Only SIGHASH_ALL commits to every output of this transaction."
        ))
      }
    }

    return findings
  }

  /// Every signature must end in SIGHASH_ALL (0x01). Any other flag leaves part of the
  /// transaction uncommitted — SIGHASH_NONE signs no outputs at all, so a valid
  /// signature could be replayed against a transaction paying somebody else.
  static func verifySighash(of signature: Data, pubkey: String, outpoint: String) -> PSBTFinding? {
    guard let flag = signature.last, signature.count >= 9 else {
      return .critical(
        Code.inputMalformedSignature,
        outpoint: outpoint,
        "Input \(outpoint) carries a signature from \(pubkey.prefix(16))… that is too short to be valid."
      )
    }

    guard flag != 0x01 else { return nil }

    return .critical(
      Code.inputNonDefaultSighash,
      outpoint: outpoint,
      "Input \(outpoint) is signed with \(sighashName(flag)) instead of SIGHASH_ALL. That signature does not commit to all of this transaction's outputs, so the coins could be redirected."
    )
  }

  private static func sighashName(_ flag: UInt8) -> String {
    switch flag {
    case 0x02: "SIGHASH_NONE"
    case 0x03: "SIGHASH_SINGLE"
    case 0x81: "SIGHASH_ALL|ANYONECANPAY"
    case 0x82: "SIGHASH_NONE|ANYONECANPAY"
    case 0x83: "SIGHASH_SINGLE|ANYONECANPAY"
    default: String(format: "sighash flag 0x%02x", flag)
    }
  }

  /// Work out which of the wallet's cosigners are represented among the master
  /// fingerprints that signed a PSBT.
  ///
  /// Both sides are normalised: PSBTs and BDK emit lowercase hex, while a cosigner's
  /// fingerprint is stored exactly as the user typed it, so a direct comparison
  /// reports "not signed" for every cosigner entered in uppercase.
  ///
  /// - Parameter signerFingerprints: master fingerprints found on signed inputs.
  /// - Returns: one entry per cosigner, in the order given, carrying the fingerprint
  ///   as stored so the UI still shows what the user typed.
  static func cosignerSignStatus(
    signerFingerprints: Set<String>,
    cosigners: [(label: String, fingerprint: String)]
  ) -> [(label: String, fingerprint: String, hasSigned: Bool)] {
    let signed = Set(signerFingerprints.map(CosignerInfo.normalizedFingerprint))
    return cosigners.map { cosigner in
      (
        label: cosigner.label,
        fingerprint: cosigner.fingerprint,
        hasSigned: signed.contains(CosignerInfo.normalizedFingerprint(cosigner.fingerprint))
      )
    }
  }

  /// Describe every output of `tx` using the wallet's own script index.
  ///
  /// The role comes from `keychainOf` — in production `Wallet.derivationOfSpk`, which
  /// answers from the scripts the wallet itself derived. That is deliberately *not*
  /// the output's `bip32Derivation`: any PSBT can populate that field with a plausible
  /// fingerprint and path, so trusting it lets a hostile PSBT label a foreign output
  /// as change. A script the wallet cannot place is external, whatever the PSBT says.
  ///
  /// - Parameter keychainOf: returns the keychain a script was derived from, or nil
  ///   when the wallet does not recognise it.
  static func classifyOutputs(
    tx: Transaction,
    network: Network,
    keychainOf: (Script) -> KeychainKind?
  ) -> [PSBTOutputInfo] {
    tx.output().enumerated().map { index, txOut in
      let role: PSBTOutputInfo.Role = switch keychainOf(txOut.scriptPubkey) {
      case .internal: .change
      case .external: .selfTransfer
      case nil: .external
      }

      return PSBTOutputInfo(
        index: index,
        address: (try? Address.fromScript(script: txOut.scriptPubkey, network: network))?.description ?? "Unknown",
        amount: txOut.value.toSat(),
        role: role
      )
    }
  }

  /// Check every output that claims to be derived from this wallet's keys.
  ///
  /// A PSBT names a derivation path for each output it says belongs to you, and a
  /// signing device that only checks "does this carry my fingerprint under my account"
  /// will accept a path this wallet can never rediscover — `48'/0'/0'/2'/127/1/0`
  /// instead of `48'/0'/0'/2'/1/0`, say. The coins are not cryptographically lost, but
  /// no restore from the descriptor will ever find them: the path lives only in a PSBT
  /// that is about to be thrown away. Anything off the wallet's own shape is critical.
  ///
  /// Shape alone is not enough, though — a plausible path proves nothing about whose
  /// key produced the script. Where the wallet can derive the claimed path
  /// (`truth.scriptAt`), the derived script must equal the output's script.
  static func verifyOutputDerivations(
    psbt: Psbt,
    tx: Transaction,
    outputs: [PSBTOutputInfo],
    against truth: PSBTGroundTruth
  ) -> [PSBTFinding] {
    guard !truth.accountOrigin.isEmpty else { return [] }

    let psbtOutputs = psbt.output()
    let txOutputs = tx.output()

    return outputs.compactMap { output in
      guard output.index < psbtOutputs.count, output.index < txOutputs.count else { return nil }
      let derivations = psbtOutputs[output.index].bip32Derivation
      // No claim, nothing to check. An output can legitimately carry no derivation.
      guard !derivations.isEmpty else { return nil }

      return verifyOutputDerivation(
        output: output,
        script: txOutputs[output.index].scriptPubkey,
        derivations: derivations,
        against: truth
      )
    }
  }

  /// Check one output's derivation claims. At most one finding — the first problem
  /// found is the one worth showing.
  static func verifyOutputDerivation(
    output: PSBTOutputInfo,
    script: Script,
    derivations: [String: KeySource],
    against truth: PSBTGroundTruth
  ) -> PSBTFinding? {
    // No claim, or no known account shape to compare a claim against.
    guard !derivations.isEmpty, !truth.accountOrigin.isEmpty else { return nil }

    let hardened: UInt32 = 0x8000_0000
    let originDepth = truth.accountOrigin.count
    let expectedDepth = originDepth + 2 // account origin + chain + address index
    let label = "Output \(output.index) (\(output.address))"

    var suffixes: Set<[UInt32]> = []
    var claimsThisWallet = false

    for (_, source) in derivations {
      let path = source.path.toU32Vec()

      guard path.count == expectedDepth else {
        return .critical(
          Code.outputDerivationDepth,
          "\(label) claims the derivation path \(pathDescription(path)), which has \(path.count) levels. This wallet's keys live \(expectedDepth) levels deep, so restoring from your descriptor would never find coins sent there."
        )
      }

      guard Array(path.prefix(originDepth)) == truth.accountOrigin else {
        return .critical(
          Code.outputDerivationOrigin,
          "\(label) claims the derivation path \(pathDescription(path)), which is not under this wallet's account \(pathDescription(truth.accountOrigin)). Coins sent there would not be covered by your descriptor."
        )
      }

      let chain = path[originDepth]
      guard chain == 0 || chain == 1 else {
        return .critical(
          Code.outputDerivationChain,
          "\(label) claims chain \(chain) in \(pathDescription(path)). This wallet only derives addresses on chain 0 (receive) and chain 1 (change), so coins sent there would not be found by a restore."
        )
      }

      guard path[originDepth + 1] < hardened else {
        return .critical(
          Code.outputDerivationHardenedIndex,
          "\(label) claims a hardened address index in \(pathDescription(path)). Hardened indexes cannot be derived from the cosigner xpubs in your descriptor."
        )
      }

      suffixes.insert(Array(path.suffix(2)))
      if truth.cosignerFingerprints.contains(CosignerInfo.normalizedFingerprint(source.fingerprint)) {
        claimsThisWallet = true
      }
    }

    guard suffixes.count == 1, let suffix = suffixes.first else {
      return .critical(
        Code.outputDerivationDisagreement,
        "\(label) gives its cosigners different address indexes. Every key of a wallet-owned output must derive from the same path."
      )
    }

    guard claimsThisWallet else {
      // Derivation data for keys this wallet does not hold. Harmless on an output
      // that is plainly someone else's, worth saying out loud otherwise.
      return output.isMine
        ? nil
        : .warning(
          Code.outputUnknownFingerprint,
          "\(label) carries key origins this wallet does not recognise. It is being treated as an ordinary recipient."
        )
    }

    let keychain: KeychainKind = suffix[0] == 1 ? .internal : .external
    let index = suffix[1]

    // The decisive test: a fingerprint and a well-formed path are trivial to forge,
    // so derive the wallet's own script at the claimed path and compare.
    guard let expected = truth.scriptAt(keychain, index) else {
      return output.isMine ? nil : .warning(
        Code.outputUnknownFingerprint,
        "\(label) claims to be yours at \(pathDescription(truth.accountOrigin + suffix)), but this wallet could not check that claim."
      )
    }

    guard expected.toBytes() == script.toBytes() else {
      return .critical(
        Code.outputDerivationScriptMismatch,
        "\(label) claims to be your \(keychain == .internal ? "change" : "receive") address at \(pathDescription(truth.accountOrigin + suffix)), but that path produces a different address in this wallet. The output is not yours."
      )
    }

    // Genuinely ours. If the script index has not been revealed yet the wallet cannot
    // see it as its own — recoverable by rescanning, but worth flagging.
    guard output.isMine else {
      return .warning(
        Code.outputBeyondGapLimit,
        "\(label) is your \(keychain == .internal ? "change" : "receive") address at index \(index), beyond the addresses this wallet has revealed. The funds are recoverable from your descriptor, but refresh the wallet so it tracks them."
      )
    }

    return nil
  }

  /// Renders BIP-32 path components the conventional way: 48'/0'/0'/2'/1/0
  private static func pathDescription(_ path: [UInt32]) -> String {
    let hardened: UInt32 = 0x8000_0000
    return path
      .map { $0 >= hardened ? "\($0 - hardened)'" : "\($0)" }
      .joined(separator: "/")
  }

  /// At most one finding per input — the first problem found is the one worth showing.
  private static func verify(
    input: Input,
    txIn: TxIn,
    outpoint: String,
    known: UInt64?
  ) -> PSBTFinding? {
    let vout = txIn.previousOutput.vout
    var nonWitnessValue: UInt64?

    if let previousTx = input.nonWitnessUtxo {
      // An embedded previous transaction must actually be the one being spent.
      // Nothing in BDK verifies this, so without the check a PSBT can attach an
      // unrelated transaction and name any amount it likes.
      let embeddedTxid = previousTx.computeTxid().description
      guard embeddedTxid == txIn.previousOutput.txid.description else {
        return .critical(
          Code.inputPrevTxidMismatch,
          outpoint: outpoint,
          "Input \(outpoint) carries a previous transaction that hashes to \(embeddedTxid) — that is not the transaction being spent"
        )
      }

      let previousOutputs = previousTx.output()
      guard Int(vout) < previousOutputs.count else {
        return .critical(
          Code.inputPrevoutOutOfRange,
          outpoint: outpoint,
          "Input \(outpoint) spends output \(vout) of a transaction that only has \(previousOutputs.count) outputs"
        )
      }
      nonWitnessValue = previousOutputs[Int(vout)].value.toSat()
    }

    let witnessValue = input.witnessUtxo?.value.toSat()

    // When both are present they must agree. Signers differ in which field they
    // trust, so a disagreement means two devices can be shown two different amounts
    // for the same input.
    if let witnessValue, let nonWitnessValue, witnessValue != nonWitnessValue {
      return .critical(
        Code.inputUtxoDisagreement,
        outpoint: outpoint,
        "Input \(outpoint) declares \(witnessValue.formattedSats) in witness_utxo but \(nonWitnessValue.formattedSats) in non_witness_utxo"
      )
    }

    // witness_utxo wins when both are present, matching how BDK computes the fee.
    guard let declared = witnessValue ?? nonWitnessValue else {
      return .critical(
        Code.inputMissingUtxo,
        outpoint: outpoint,
        "Input \(outpoint) carries no UTXO data, so the amount it contributes cannot be checked"
      )
    }

    guard let known else {
      return .warning(
        Code.inputAmountUnverifiable,
        outpoint: outpoint,
        "Input \(outpoint) declares \(declared.formattedSats), which this wallet cannot confirm — the output is not in its history. Refresh the wallet, or treat the fee shown as unverified."
      )
    }

    guard declared == known else {
      return .critical(
        Code.inputAmountMismatch,
        outpoint: outpoint,
        "Input \(outpoint) declares \(declared.formattedSats) but this wallet knows that output holds \(known.formattedSats)"
      )
    }

    return nil
  }
}

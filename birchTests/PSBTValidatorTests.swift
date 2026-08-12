@testable import birch
import BitcoinDevKit
import Foundation
import Testing

/// Bundle anchor for fixture lookup.
private final class ValidatorBundleToken {}

@Suite("PSBT input amount verification")
struct PSBTValidatorTests {
  // MARK: - Fixture

  /// `test_psbt_nonwitness` is a well-formed 2-in / 2-out PSBT. Both inputs carry a
  /// witness_utxo *and* a non_witness_utxo whose txid hashes to the outpoint being
  /// spent, which makes it a usable stand-in for a PSBT this wallet built itself.
  private let input0 = "59166bae12f29d479f00d9102fba241855596ce50ec877503ed497012b43fb50:1"
  private let input1 = "63af5d2ea0139b0d276e81bc744904389d58a52067e178201d203d39a515f0b7:2"
  private let input0Sats: UInt64 = 60000
  private let input1Sats: UInt64 = 40000

  private var truth: PSBTGroundTruth {
    PSBTGroundTruth(knownOutputAmounts: [input0: input0Sats, input1: input1Sats])
  }

  private func loadFixture(_ name: String) -> Data? {
    let bundle = Bundle(for: ValidatorBundleToken.self)
    guard let path = bundle.path(forResource: name, ofType: "txt"),
          let base64 = try? String(contentsOfFile: path, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    return Data(base64Encoded: base64)
  }

  private func fixture() throws -> Data {
    try #require(loadFixture("test_psbt_nonwitness"), "fixture missing from the test bundle")
  }

  // MARK: - Byte surgery helpers

  /// A witness_utxo map entry: key length, key type 0x01, value length 0x2B,
  /// then the 8-byte little-endian amount. The trailing 35 script bytes are left
  /// out so the prefix can be matched and the amount rewritten in place.
  private func witnessUtxoPrefix(_ sats: UInt64) -> Data {
    Data([0x01, 0x01, 0x2B]) + withUnsafeBytes(of: sats.littleEndian) { Data($0) }
  }

  /// Rewrite an input's declared witness_utxo amount, leaving every length untouched.
  private func rewritingWitnessAmount(in psbt: Data, from old: UInt64, to new: UInt64) throws -> Data {
    let target = witnessUtxoPrefix(old)
    let range = try #require(psbt.range(of: target), "witness_utxo entry for \(old) sats not found")
    var patched = psbt
    patched.replaceSubrange(range, with: witnessUtxoPrefix(new))
    return patched
  }

  /// Drop an input's witness_utxo entry entirely (3 header + 43 value bytes),
  /// leaving only its non_witness_utxo.
  private func removingWitnessUtxo(_ sats: UInt64, from psbt: Data) throws -> Data {
    let range = try #require(psbt.range(of: witnessUtxoPrefix(sats)), "witness_utxo entry not found")
    var patched = psbt
    patched.removeSubrange(range.lowerBound ..< psbt.index(range.lowerBound, offsetBy: 46))
    return patched
  }

  private func parse(_ psbtData: Data) throws -> (Psbt, Transaction) {
    let psbt = try Psbt(psbtBase64: psbtData.base64EncodedString())
    return try (psbt, psbt.extractTx())
  }

  private func verify(_ psbtData: Data, against truth: PSBTGroundTruth) throws -> [PSBTFinding] {
    let (psbt, tx) = try parse(psbtData)
    return PSBTValidator.verifyInputAmounts(psbt: psbt, tx: tx, against: truth)
  }

  // MARK: - Baseline

  @Test("A PSBT whose amounts match wallet state produces no findings")
  func honestPSBTPasses() throws {
    #expect(try verify(fixture(), against: truth).isEmpty)
  }

  @Test("The fixture parses and both UTXO representations agree")
  func fixtureIsWellFormed() throws {
    let (psbt, tx) = try parse(fixture())
    #expect(psbt.input().count == 2)
    #expect(tx.input().count == 2)
    for input in psbt.input() {
      #expect(input.witnessUtxo != nil)
      #expect(input.nonWitnessUtxo != nil)
    }
  }

  // MARK: - Lying amounts

  @Test("An inflated witness_utxo amount is critical")
  func inflatedAmountIsCritical() throws {
    // Strip non_witness_utxo first so witness_utxo is the only declaration —
    // this is exactly the payload compact-QR mode sends to a signer.
    let witnessOnly = try PSBTCompactor.compact(fixture())
    let lying = try rewritingWitnessAmount(in: witnessOnly, from: input0Sats, to: 90000)

    let findings = try verify(lying, against: truth)
    #expect(findings.count == 1)
    #expect(findings.first?.severity == .critical)
    #expect(findings.first?.code == PSBTFinding.Code.inputAmountMismatch)
    #expect(findings.first?.outpoint == input0)
  }

  @Test("A deflated witness_utxo amount — the fee-inflation direction — is critical")
  func deflatedAmountIsCritical() throws {
    // The fixture's outputs total 99,500 sats, so the deflation has to stay above
    // that to remain extractable — see `extremeDeflationIsRejectedBeforeVerification`
    // for what happens past that point.
    let witnessOnly = try PSBTCompactor.compact(fixture())
    let lying = try rewritingWitnessAmount(in: witnessOnly, from: input0Sats, to: 59600)

    let findings = try verify(lying, against: truth)
    #expect(findings.count == 1)
    #expect(findings.first?.code == PSBTFinding.Code.inputAmountMismatch)
    #expect(findings.first?.outpoint == input0)
  }

  @Test("Only the lying input is reported")
  func onlyTheLyingInputIsReported() throws {
    let witnessOnly = try PSBTCompactor.compact(fixture())
    let lying = try rewritingWitnessAmount(in: witnessOnly, from: input1Sats, to: 39900)

    let findings = try verify(lying, against: truth)
    #expect(findings.count == 1)
    #expect(findings.first?.outpoint == input1)
  }

  // MARK: - Cases BDK rejects before the validator runs

  //
  // These document the upstream half of the defence. `BitcoinService.verifyPSBT`
  // turns each of these into a critical `psbt.unextractable` finding, so the
  // outcome for the user is the same: the operation is blocked.

  @Test("A deflation large enough to invert the fee is rejected by extraction")
  func extremeDeflationIsRejectedBeforeVerification() throws {
    let witnessOnly = try PSBTCompactor.compact(fixture())
    let lying = try rewritingWitnessAmount(in: witnessOnly, from: input0Sats, to: 6000)

    let psbt = try Psbt(psbtBase64: lying.base64EncodedString())
    // Declared inputs now total less than the outputs — ExtractTxError.sendingTooMuch.
    #expect(throws: (any Error).self) { try psbt.extractTx() }
  }

  @Test("An input stripped of all UTXO data is rejected by extraction")
  func missingUtxoDataIsRejectedBeforeVerification() throws {
    let noNonWitness = try PSBTCompactor.compact(fixture())
    let stripped = try removingWitnessUtxo(input0Sats, from: noNonWitness)

    let psbt = try Psbt(psbtBase64: stripped.base64EncodedString())
    // No witness_utxo and no non_witness_utxo — ExtractTxError.missingInputValue.
    #expect(throws: (any Error).self) { try psbt.extractTx() }
  }

  @Test("witness_utxo and non_witness_utxo disagreeing is critical")
  func utxoDisagreementIsCritical() throws {
    // Both representations present, only the witness one rewritten: two signers
    // reading different fields would be shown different amounts.
    let lying = try rewritingWitnessAmount(in: fixture(), from: input0Sats, to: 90000)

    let findings = try verify(lying, against: truth)
    #expect(findings.count == 1)
    #expect(findings.first?.code == PSBTFinding.Code.inputUtxoDisagreement)
    #expect(findings.first?.outpoint == input0)
  }

  // MARK: - Embedded previous transaction

  @Test("An embedded previous transaction must hash to the outpoint being spent")
  func previousTransactionTxidIsChecked() throws {
    // Flip one byte inside input 0's embedded previous transaction. Its txid changes;
    // every length, and the referenced output's value, stay as they were.
    let original = try fixture()
    let marker = Data(repeating: 0x11, count: 32)
    let range = try #require(original.range(of: marker))
    var corrupted = original
    corrupted.replaceSubrange(range, with: Data(repeating: 0x11, count: 31) + Data([0x12]))

    let findings = try verify(corrupted, against: truth)
    #expect(findings.count == 1)
    #expect(findings.first?.code == PSBTFinding.Code.inputPrevTxidMismatch)
    #expect(findings.first?.outpoint == input0)
  }

  @Test("An input with only a non_witness_utxo verifies from the embedded transaction")
  func nonWitnessOnlyInputVerifies() throws {
    var stripped = try removingWitnessUtxo(input0Sats, from: fixture())
    stripped = try removingWitnessUtxo(input1Sats, from: stripped)

    let (psbt, _) = try parse(stripped)
    #expect(psbt.input().allSatisfy { $0.witnessUtxo == nil && $0.nonWitnessUtxo != nil })
    #expect(try verify(stripped, against: truth).isEmpty)
  }

  // MARK: - Unverifiable inputs never block

  @Test("An outpoint the wallet does not know is a warning, not a failure")
  func unknownOutpointIsWarning() throws {
    let partial = PSBTGroundTruth(knownOutputAmounts: [input0: input0Sats])

    let findings = try verify(fixture(), against: partial)
    #expect(findings.count == 1)
    #expect(findings.first?.severity == .warning)
    #expect(findings.first?.code == PSBTFinding.Code.inputAmountUnverifiable)
    #expect(findings.first?.outpoint == input1)
    #expect(!findings.hasCritical)
  }

  @Test("An unsynced wallet warns on every input and blocks nothing")
  func emptyGroundTruthOnlyWarns() throws {
    let findings = try verify(fixture(), against: PSBTGroundTruth(knownOutputAmounts: [:]))
    #expect(findings.count == 2)
    #expect(findings.warnings.count == 2)
    #expect(!findings.hasCritical)
  }

  @Test("A lie is still caught when other inputs are unverifiable")
  func mismatchWinsOverUnverifiable() throws {
    let witnessOnly = try PSBTCompactor.compact(fixture())
    let lying = try rewritingWitnessAmount(in: witnessOnly, from: input0Sats, to: 90000)
    let partial = PSBTGroundTruth(knownOutputAmounts: [input0: input0Sats])

    let findings = try verify(lying, against: partial)
    #expect(findings.criticals.count == 1)
    #expect(findings.criticals.first?.outpoint == input0)
    #expect(findings.warnings.count == 1)
    #expect(findings.warnings.first?.outpoint == input1)
  }

  // MARK: - Output classification

  /// The fixture pays 70,000 sats to a P2WPKH output and 29,500 sats to the P2WSH
  /// script the wallet's own inputs use. Only output 1 carries `bip32Derivation`.
  private func fixtureOutputs() throws -> (tx: Transaction, external: Data, walletScript: Data) {
    let (_, tx) = try parse(fixture())
    let outs = tx.output()
    return (tx, outs[0].scriptPubkey.toBytes(), outs[1].scriptPubkey.toBytes())
  }

  @Test("An internal-keychain output is change")
  func internalKeychainOutputIsChange() throws {
    let (tx, _, walletScript) = try fixtureOutputs()

    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { script in
      script.toBytes() == walletScript ? .internal : nil
    }

    #expect(outputs.count == 2)
    #expect(outputs[0].role == .external)
    #expect(outputs[0].amount == 70000)
    #expect(outputs[1].role == .change)
    #expect(outputs[1].amount == 29500)
    #expect(outputs[1].isMine)
  }

  @Test("An external-keychain output is a self-transfer, not change")
  func externalKeychainOutputIsSelfTransfer() throws {
    let (tx, externalScript, _) = try fixtureOutputs()

    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { script in
      script.toBytes() == externalScript ? .external : nil
    }

    #expect(outputs[0].role == .selfTransfer)
    #expect(outputs[0].isMine, "A self-send is still ours")
    #expect(outputs.allSatisfy { $0.role != .change }, "Nothing here is change")
  }

  @Test("An output the wallet cannot place is external, whatever the PSBT claims")
  func unrecognisedScriptIsExternalDespiteDerivationData() throws {
    // Output 1 carries bip32Derivation in the fixture. The old rule keyed off exactly
    // that field, so it would have called this output change; the wallet's own index
    // is the only thing that decides now.
    let (tx, _, _) = try fixtureOutputs()

    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { _ in nil }

    #expect(outputs.allSatisfy { $0.role == .external })
    #expect(outputs.allSatisfy { !$0.isMine })
  }

  @Test("Every wallet-owned output is reported, not just the last one")
  func multipleWalletOutputsAreAllReported() throws {
    let (tx, _, _) = try fixtureOutputs()

    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { _ in .internal }

    #expect(outputs.filter { $0.role == .change }.count == 2)
    #expect(outputs.map(\.index) == [0, 1])
  }

  @Test("Addresses are derived for the network in use")
  func addressesUseTheGivenNetwork() throws {
    let (tx, _, _) = try fixtureOutputs()

    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { _ in nil }

    #expect(outputs.allSatisfy { $0.address.hasPrefix("tb1") })
  }

  // MARK: - Change derivation paths

  /// Both fixture cosigners, as recorded in the fixture's output derivations.
  private let cosignerA = "aabbccdd"
  private let cosignerB = "11223344"

  private func keySource(_ fingerprint: String, _ path: String) throws -> KeySource {
    try KeySource(fingerprint: fingerprint, path: DerivationPath(path: path))
  }

  private func script(_ marker: UInt8) -> Script {
    Script(rawOutputScript: Data([0x00, 0x14] + Data(repeating: marker, count: 20)))
  }

  /// Ground truth for a testnet BIP-48 account-0 wallet (48'/1'/0'/2').
  private func derivationTruth(
    fingerprints: Set<String>? = nil,
    scriptAt: @escaping (KeychainKind, UInt32) -> Script? = { _, _ in nil }
  ) -> PSBTGroundTruth {
    PSBTGroundTruth(
      knownOutputAmounts: [:],
      accountOrigin: PSBTGroundTruth.accountOrigin(for: .testnet4),
      cosignerFingerprints: fingerprints ?? [cosignerA, cosignerB],
      scriptAt: scriptAt
    )
  }

  private func output(_ role: PSBTOutputInfo.Role) -> PSBTOutputInfo {
    PSBTOutputInfo(index: 1, address: "tb1qexample", amount: 29500, role: role)
  }

  /// Runs the per-output check with both cosigners claiming the same path.
  private func checkPath(
    _ path: String,
    role: PSBTOutputInfo.Role = .change,
    outputScript: UInt8 = 0xAA,
    truth: PSBTGroundTruth? = nil
  ) throws -> PSBTFinding? {
    try PSBTValidator.verifyOutputDerivation(
      output: output(role),
      script: script(outputScript),
      derivations: [
        "pubkeyA": keySource(cosignerA, path),
        "pubkeyB": keySource(cosignerB, path),
      ],
      against: truth ?? derivationTruth(scriptAt: { _, _ in script(outputScript) })
    )
  }

  @Test("A standard change path that derives the right script passes")
  func standardChangePathPasses() throws {
    #expect(try checkPath("m/48'/1'/0'/2'/1/0") == nil)
  }

  @Test("A standard receive path on a self-transfer passes")
  func standardReceivePathPasses() throws {
    #expect(try checkPath("m/48'/1'/0'/2'/0/7", role: .selfTransfer) == nil)
  }

  @Test("Extra derivation depth is critical")
  func extraDepthIsCritical() throws {
    // The attack shape: valid account origin, then an unexpected extra level. No
    // restore from the descriptor would ever look here.
    let finding = try checkPath("m/48'/1'/0'/2'/127/1/0")
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.outputDerivationDepth)
  }

  @Test("A chain other than receive or change is critical")
  func wrongChainIsCritical() throws {
    let finding = try checkPath("m/48'/1'/0'/2'/2/0")
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.outputDerivationChain)
  }

  @Test("A path outside this wallet's account is critical")
  func wrongAccountOriginIsCritical() throws {
    // Right depth, wrong account: BIP-84 single-sig rather than BIP-48 account 0.
    let finding = try checkPath("m/84'/1'/0'/0'/1/0")
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.outputDerivationOrigin)
  }

  @Test("A hardened address index is critical")
  func hardenedIndexIsCritical() throws {
    let finding = try checkPath("m/48'/1'/0'/2'/1/0'")
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.outputDerivationHardenedIndex)
  }

  @Test("Cosigners claiming different indexes is critical")
  func cosignersDisagreeingIsCritical() throws {
    let finding = try PSBTValidator.verifyOutputDerivation(
      output: output(.change),
      script: script(0xAA),
      derivations: [
        "pubkeyA": keySource(cosignerA, "m/48'/1'/0'/2'/1/0"),
        "pubkeyB": keySource(cosignerB, "m/48'/1'/0'/2'/1/9"),
      ],
      against: derivationTruth(scriptAt: { _, _ in script(0xAA) })
    )
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.outputDerivationDisagreement)
  }

  @Test("A plausible path that derives a different script is critical")
  func forgedPathIsCritical() throws {
    // Well-formed path, real cosigner fingerprints — but the wallet's own key at that
    // path produces a different address, so the output is not ours. This is the case
    // shape checks alone cannot catch.
    let finding = try checkPath(
      "m/48'/1'/0'/2'/1/4",
      role: .external,
      outputScript: 0xAA,
      truth: derivationTruth(scriptAt: { _, _ in script(0xBB) })
    )
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.outputDerivationScriptMismatch)
  }

  @Test("A genuine address beyond the gap limit warns rather than blocking")
  func beyondGapLimitWarns() throws {
    // Path checks out and the script matches what this wallet derives — the wallet
    // just has not revealed that far, so it could not recognise it as its own.
    let finding = try checkPath(
      "m/48'/1'/0'/2'/1/900000",
      role: .external,
      truth: derivationTruth(scriptAt: { _, _ in script(0xAA) })
    )
    #expect(finding?.severity == .warning)
    #expect(finding?.code == PSBTFinding.Code.outputBeyondGapLimit)
  }

  @Test("Derivation data for keys this wallet does not hold warns")
  func unknownFingerprintWarns() throws {
    let finding = try checkPath(
      "m/48'/1'/0'/2'/1/0",
      role: .external,
      truth: derivationTruth(fingerprints: ["deadbeef"])
    )
    #expect(finding?.severity == .warning)
    #expect(finding?.code == PSBTFinding.Code.outputUnknownFingerprint)
  }

  @Test("Fingerprint comparison ignores case")
  func fingerprintCaseIsIgnored() throws {
    let finding = try PSBTValidator.verifyOutputDerivation(
      output: output(.change),
      script: script(0xAA),
      derivations: ["pubkeyA": keySource("AABBCCDD", "m/48'/1'/0'/2'/1/0")],
      against: derivationTruth(fingerprints: ["aabbccdd"], scriptAt: { _, _ in script(0xAA) })
    )
    #expect(finding == nil, "An uppercase fingerprint is the same fingerprint")
  }

  @Test("Without a known account origin nothing is claimed either way")
  func noAccountOriginSkipsTheCheck() throws {
    let finding = try checkPath(
      "m/48'/1'/0'/2'/127/1/0",
      truth: PSBTGroundTruth(knownOutputAmounts: [:])
    )
    #expect(finding == nil)
  }

  @Test("The fixture's own output derivations pass end to end")
  func fixtureDerivationsPass() throws {
    let (tx, _, walletScript) = try fixtureOutputs()
    let psbt = try Psbt(psbtBase64: fixture().base64EncodedString())
    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { script in
      script.toBytes() == walletScript ? .external : nil
    }

    // The fixture claims m/48'/1'/0'/2'/0/0 on output 1; hand back its own script.
    let findings = PSBTValidator.verifyOutputDerivations(
      psbt: psbt,
      tx: tx,
      outputs: outputs,
      against: derivationTruth(scriptAt: { _, _ in Script(rawOutputScript: walletScript) })
    )
    #expect(findings.isEmpty)
  }

  @Test("An output with no derivation data is not second-guessed")
  func outputsWithoutDerivationDataAreIgnored() throws {
    let (tx, _, _) = try fixtureOutputs()
    let psbt = try Psbt(psbtBase64: fixture().base64EncodedString())
    // Output 0 carries no bip32Derivation at all — an ordinary recipient.
    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: .testnet) { _ in nil }

    let findings = PSBTValidator.verifyOutputDerivations(
      psbt: psbt, tx: tx, outputs: [outputs[0]], against: derivationTruth()
    )
    #expect(findings.isEmpty)
  }

  // MARK: - Signatures: whose keys, and what they commit to

  /// Both pubkeys in the fixture's 2-of-2 witness script.
  private let scriptPubkeyA = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
  private let scriptPubkeyB = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

  /// A signature blob of plausible length ending in the given sighash flag.
  private func signature(flag: UInt8) -> Data {
    Data(repeating: 0x30, count: 70) + Data([flag])
  }

  /// Splice a key-value entry into input 0's map, just after its witness_utxo entry.
  private func insertingIntoFirstInput(_ entry: Data, of psbt: Data) throws -> Data {
    let anchor = try #require(psbt.range(of: witnessUtxoPrefix(input0Sats)))
    var patched = psbt
    patched.insert(contentsOf: entry, at: anchor.lowerBound + 46)
    return patched
  }

  @Test("Verified keys come from the witness script the output commits to")
  func verifiedPubkeysAreTakenFromTheCommittedScript() throws {
    let (psbt, tx) = try parse(fixture())
    let verified = try #require(
      PSBTValidator.verifiedPubkeys(input: psbt.input()[0], txIn: tx.input()[0])
    )

    #expect(verified == [scriptPubkeyA, scriptPubkeyB])
  }

  @Test("A witness script that does not hash to the spent output is critical")
  func witnessScriptMismatchIsCritical() throws {
    // Flip the first byte of input 0's witness script (OP_2 → OP_3). Lengths are
    // untouched, but it no longer hashes to the P2WSH commitment in the output being
    // spent, so nothing the script says about keys can be trusted.
    let original = try fixture()
    // PSBT_IN_WITNESS_SCRIPT: key length 1, key type 0x05, value length 0x47 (71).
    let entry = try #require(original.range(of: Data([0x01, 0x05, 0x47])))
    var corrupted = original
    corrupted[entry.lowerBound + 3] = 0x53

    let (psbt, tx) = try parse(corrupted)
    #expect(PSBTValidator.verifiedPubkeys(input: psbt.input()[0], txIn: tx.input()[0]) == [])

    let findings = PSBTValidator.verifySignatures(psbt: psbt, tx: tx)
    #expect(findings.count == 1)
    #expect(findings[0].severity == .critical)
    #expect(findings[0].code == PSBTFinding.Code.inputWitnessScriptMismatch)
    #expect(findings[0].outpoint == input0)
  }

  @Test("An honest PSBT raises no signature findings")
  func honestPSBTHasNoSignatureFindings() throws {
    let (psbt, tx) = try parse(fixture())
    #expect(PSBTValidator.verifySignatures(psbt: psbt, tx: tx).isEmpty)
  }

  @Test("SIGHASH_ALL is the only accepted flag")
  func sighashAllPasses() {
    #expect(PSBTValidator.verifySighash(of: signature(flag: 0x01), pubkey: "02aa", outpoint: "aa:0") == nil)
  }

  @Test("SIGHASH_NONE is critical — it commits to no outputs at all")
  func sighashNoneIsCritical() {
    let finding = PSBTValidator.verifySighash(of: signature(flag: 0x02), pubkey: "02aa", outpoint: "aa:0")
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.inputNonDefaultSighash)
    #expect(finding?.message.contains("SIGHASH_NONE") == true)
  }

  @Test("Other non-default sighash flags are critical too", arguments: [
    UInt8(0x03), UInt8(0x81), UInt8(0x82), UInt8(0x83), UInt8(0x00),
  ])
  func otherSighashFlagsAreCritical(flag: UInt8) {
    let finding = PSBTValidator.verifySighash(of: signature(flag: flag), pubkey: "02aa", outpoint: "aa:0")
    #expect(finding?.severity == .critical)
    #expect(finding?.code == PSBTFinding.Code.inputNonDefaultSighash)
  }

  @Test("A signature too short to be real is critical")
  func shortSignatureIsMalformed() {
    let finding = PSBTValidator.verifySighash(of: Data([0x30, 0x01]), pubkey: "02aa", outpoint: "aa:0")
    #expect(finding?.code == PSBTFinding.Code.inputMalformedSignature)
  }

  @Test("An input asking signers for a non-default sighash is critical")
  func declaredNonDefaultSighashIsCritical() throws {
    // PSBT_IN_SIGHASH_TYPE (key 0x03) carrying SIGHASH_NONE as a 4-byte LE value.
    let entry = Data([0x01, 0x03, 0x04, 0x02, 0x00, 0x00, 0x00])
    let patched = try insertingIntoFirstInput(entry, of: fixture())

    let (psbt, tx) = try parse(patched)
    let findings = PSBTValidator.verifySignatures(psbt: psbt, tx: tx)
    #expect(findings.count == 1)
    #expect(findings[0].code == PSBTFinding.Code.inputNonDefaultSighash)
    #expect(findings[0].message.contains("SIGHASH_NONE") == true)
  }

  @Test("An input declaring SIGHASH_ALL explicitly is fine")
  func declaredSighashAllPasses() throws {
    let entry = Data([0x01, 0x03, 0x04, 0x01, 0x00, 0x00, 0x00])
    let patched = try insertingIntoFirstInput(entry, of: fixture())

    let (psbt, tx) = try parse(patched)
    #expect(PSBTValidator.verifySignatures(psbt: psbt, tx: tx).isEmpty)
  }

  // MARK: - Cosigner signing status

  @Test("A cosigner entered in uppercase is still matched")
  func signerStatusIgnoresFingerprintCase() {
    // BDK and PSBTs emit lowercase hex; the cosigner was typed in uppercase. These
    // are the same key, and a raw comparison used to report "not signed".
    let status = PSBTValidator.cosignerSignStatus(
      signerFingerprints: ["aabbccdd"],
      cosigners: [(label: "Coldcard", fingerprint: "AABBCCDD")]
    )

    #expect(status.count == 1)
    #expect(status[0].hasSigned)
    #expect(status[0].fingerprint == "AABBCCDD", "Display keeps what the user typed")
  }

  @Test("Mixed case on either side matches")
  func signerStatusHandlesMixedCase() {
    let status = PSBTValidator.cosignerSignStatus(
      signerFingerprints: ["AaBbCcDd"],
      cosigners: [(label: "A", fingerprint: "aAbBcCdD")]
    )
    #expect(status[0].hasSigned)
  }

  @Test("Cosigners that did not sign stay unsigned")
  func signerStatusLeavesNonSignersAlone() {
    let status = PSBTValidator.cosignerSignStatus(
      signerFingerprints: ["aabbccdd"],
      cosigners: [
        (label: "Signed", fingerprint: "AABBCCDD"),
        (label: "Not signed", fingerprint: "11223344"),
      ]
    )

    #expect(status[0].hasSigned)
    #expect(!status[1].hasSigned)
    #expect(status.map(\.label) == ["Signed", "Not signed"], "Order is preserved")
  }

  @Test("Surrounding whitespace does not break matching")
  func signerStatusToleratesWhitespace() {
    let status = PSBTValidator.cosignerSignStatus(
      signerFingerprints: ["aabbccdd"],
      cosigners: [(label: "A", fingerprint: " AABBCCDD ")]
    )
    #expect(status[0].hasSigned)
  }

  @Test("No signatures means nobody is marked as having signed")
  func signerStatusWithNoSignatures() {
    let status = PSBTValidator.cosignerSignStatus(
      signerFingerprints: [],
      cosigners: [(label: "A", fingerprint: "aabbccdd")]
    )
    #expect(!status[0].hasSigned)
  }

  // MARK: - Ground truth assembly

  @Test("Ground truth covers unspent outputs")
  func groundTruthFromUTXOs() {
    let utxo = UTXOItem(
      txid: "aa", vout: 1, amount: 500, isConfirmed: true,
      keychain: .external, derivationIndex: 0
    )
    let truth = PSBTGroundTruth.from(utxos: [utxo], transactions: [], network: .testnet4)
    #expect(truth.knownOutputAmounts["aa:1"] == 500)
  }

  @Test("Ground truth covers outputs already spent — the RBF case")
  func groundTruthCoversSpentOutputs() {
    // A bump PSBT spends the original transaction's inputs, which are no longer
    // unspent. Without the transaction half of the map they would be unverifiable.
    let previous = TransactionItem(
      id: "bb",
      amount: -1000,
      fee: 200,
      confirmations: 0,
      timestamp: nil,
      isIncoming: false,
      outputs: [
        .init(address: "addr0", amount: 111, prevTxid: nil, prevVout: nil, isMine: false),
        .init(address: "addr1", amount: 222, prevTxid: nil, prevVout: nil, isMine: true),
      ]
    )

    let truth = PSBTGroundTruth.from(utxos: [], transactions: [previous], network: .testnet4)
    #expect(truth.knownOutputAmounts["bb:0"] == 111)
    #expect(truth.knownOutputAmounts["bb:1"] == 222)
  }
}

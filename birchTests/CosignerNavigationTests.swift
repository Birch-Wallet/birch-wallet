@testable import birch
import Foundation
import Testing

/// Import cosigners: tabs switch freely, the tab checks are live, and Next
/// flags the open cosigner or moves to the next incomplete one, wrapping.
@MainActor
struct CosignerNavigationTests {
  /// Testnet keys at m/48'/1'/0'/2', from the screenshot tour
  private static let keys: [(xpub: String, fingerprint: String)] = [
    ("tpubDE2gU1F6b1GXDg2bFjeq6RUnBmAe2moTNG7x47Cga3VnVnm7EJWLdJE73ZL2MEwKTc2dLNeSudXUjexm2xJ5qboosbnEb1SEiGyJtJcqqZK", "07d25f0c"),
    ("tpubDET5GnMK8Zr7UH63ni72etKd7ZYxVq8NvtSneNBfEDJ7YtnSHUmiPCaBYXzCdR6ZBKWvBMXT3urCVp7sLmG6z8VTpdFRJuW4VL7xjHdLFpY", "d73869a4"),
    ("tpubDF3GwUrMb5WkigsDUpUWUADH55G3Ez771QujmFqeyrNEPD7onkqTwCsCEjNRbSrbD9VYKDfMHfg7bajem5aEX7CyMp2q5fvQzacy75bUesQ", "e3870581"),
  ]

  /// A 2-of-3 wizard on Import cosigners, on the first cosigner, with nothing entered
  private static func wizard() -> SetupWizardViewModel {
    let vm = SetupWizardViewModel()
    vm.creationMode = .createNew
    vm.network = .testnet4
    vm.requiredSignatures = 2
    vm.totalCosigners = 3
    vm.currentStep = .multisigConfig
    vm.goToNext()
    return vm
  }

  private static func fill(_ vm: SetupWizardViewModel, _ index: Int) {
    vm.cosignerXpubs[index] = keys[index].xpub
    vm.cosignerFingerprints[index] = keys[index].fingerprint
  }

  // MARK: - Steps and progress

  @Test func `creating A wallet counts three steps`() {
    let vm = Self.wizard()
    #expect(vm.currentStep == .cosignerImport)
    #expect(vm.stepCount == 3)
    #expect(vm.currentStepIndex == 1)
    #expect(vm.showsProgress)

    vm.currentStep = .multisigConfig
    #expect(vm.currentStepIndex == 0)
    vm.currentStep = .verify
    #expect(vm.currentStepIndex == 2)

    for step in [SetupWizardViewModel.Step.welcome, .creationChoice] {
      vm.currentStep = step
      #expect(!vm.showsProgress, "\(step) shows no progress")
    }
  }

  @Test func `importing A descriptor shows no progress`() {
    let vm = SetupWizardViewModel()
    vm.creationMode = .importDescriptor
    vm.currentStep = .descriptorImport
    #expect(!vm.showsProgress)
  }

  @Test func `verify goes back to the cosigners`() {
    let vm = Self.wizard()
    vm.currentStep = .verify
    vm.currentCosignerIndex = 2
    vm.goBack()
    #expect(vm.currentStep == .cosignerImport)
    #expect(vm.currentCosignerIndex == 2)
    vm.goBack()
    #expect(vm.currentStep == .multisigConfig)
  }

  /// Mainnet has no default Electrum server
  @Test func `multisig needs A host on mainnet`() {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    vm.currentStep = .multisigConfig
    #expect(!vm.goToNext())
    #expect(vm.currentStep == .multisigConfig)
    #expect(vm.electrumHostError != nil)
    #expect(vm.errorMessage == nil, "The Host field is flagged instead of an alert")

    vm.changeNetwork(to: .testnet4)
    #expect(vm.electrumHostError == nil)
  }

  // MARK: - Completeness

  @Test func `a cosigner is complete when every field validates`() {
    let vm = Self.wizard()
    #expect(!vm.isCosignerComplete(0))
    #expect(vm.cosignerProblems(at: 0)[.xpub] == "Xpub is required")
    #expect(vm.cosignerProblems(at: 0)[.fingerprint] == "Fingerprint is required")
    #expect(vm.cosignerProblems(at: 0)[.path] == nil)

    vm.cosignerXpubs[0] = Self.keys[0].xpub
    #expect(!vm.isCosignerComplete(0), "Not complete without a fingerprint")
    vm.cosignerFingerprints[0] = "07d25f0"
    #expect(vm.cosignerProblems(at: 0)[.fingerprint] == "Fingerprint must be 8 hex characters")
    vm.cosignerFingerprints[0] = Self.keys[0].fingerprint
    #expect(vm.isCosignerComplete(0))
    #expect(!vm.allCosignersComplete)

    Self.fill(vm, 1)
    Self.fill(vm, 2)
    #expect(vm.allCosignersComplete)
  }

  @Test func `duplicate keys leave both cosigners incomplete`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    Self.fill(vm, 1)
    vm.cosignerXpubs[1] = Self.keys[0].xpub
    #expect(!vm.isCosignerComplete(0))
    #expect(!vm.isCosignerComplete(1))
    #expect(vm.cosignerProblems(at: 1)[.xpub] == "Duplicate xpub (same as Cosigner 1)")
  }

  // MARK: - Next

  @Test func `next flags an incomplete cosigner and stays`() {
    let vm = Self.wizard()
    let action = vm.goToNextCosigner()
    #expect(action == .flag([.xpub: "Xpub is required", .fingerprint: "Fingerprint is required"]))
    #expect(vm.currentCosignerIndex == 0)
    #expect(vm.cosignerErrors[0]?[.xpub] == "Xpub is required")
    #expect(vm.cosignerErrors[0]?[.fingerprint] == "Fingerprint is required")
  }

  @Test func `editing A field clears its flag`() {
    let vm = Self.wizard()
    vm.goToNextCosigner()
    let before = vm.cosignerXpubs
    vm.cosignerXpubs[0] = "tpub"
    vm.clearErrors(.xpub, editedFrom: before, to: vm.cosignerXpubs)
    #expect(vm.cosignerErrors[0]?[.xpub] == nil)
    #expect(vm.cosignerErrors[0]?[.fingerprint] != nil, "Only the edited field clears")

    // Whitespace alone is not an edit
    let padded = vm.cosignerFingerprints
    vm.cosignerFingerprints[0] = " "
    vm.clearErrors(.fingerprint, editedFrom: padded, to: vm.cosignerFingerprints)
    #expect(vm.cosignerErrors[0]?[.fingerprint] != nil)
  }

  @Test func `next opens the next cosigner clean`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    #expect(vm.goToNextCosigner() == .open(1, flagged: false))
    #expect(vm.currentCosignerIndex == 1)
    #expect(vm.cosignerErrors[1] == nil)
    #expect(vm.visitedCosigners == [0, 1])
  }

  @Test func `next skips complete cosigners`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    Self.fill(vm, 1)
    #expect(vm.goToNextCosigner() == .open(2, flagged: false))
  }

  /// Skip cosigner 1, complete 2 and 3: Next wraps round to 1 and flags it,
  /// because it was opened and left incomplete
  @Test func `next wraps round to A visited cosigner and flags it`() {
    let vm = Self.wizard()
    vm.openCosigner(1)
    Self.fill(vm, 1)
    #expect(vm.goToNextCosigner() == .open(2, flagged: false))
    Self.fill(vm, 2)
    #expect(vm.goToNextCosigner() == .open(0, flagged: true))
    #expect(vm.currentCosignerIndex == 0)
    #expect(vm.cosignerErrors[0]?[.xpub] == "Xpub is required")
    #expect(vm.cosignerErrors[0]?[.fingerprint] == "Fingerprint is required")
  }

  @Test func `an unvisited cosigner opens clean`() {
    let vm = Self.wizard()
    vm.openCosigner(2)
    Self.fill(vm, 2)
    // Wraps past the end to cosigner 1, which was visited on arrival
    #expect(vm.goToNextCosigner() == .open(0, flagged: true))
    Self.fill(vm, 0)
    // Cosigner 2 was never opened
    #expect(vm.goToNextCosigner() == .open(1, flagged: false))
    #expect(vm.cosignerErrors[1] == nil)
  }

  @Test func `next finishes once every cosigner is complete`() {
    let vm = Self.wizard()
    Self.useUnreachableElectrumServer(vm)
    for index in 0 ..< 3 {
      Self.fill(vm, index)
    }
    // Surrounding whitespace is dropped before the key is checked and stored
    vm.cosignerXpubs[2] += "\n"
    vm.openCosigner(1)
    #expect(vm.goToNextCosigner() == .finish)
    #expect(vm.currentStep == .verify, "\(vm.errorMessage ?? "")")
    #expect(vm.cosignerXpubs[2] == Self.keys[2].xpub)
    #expect(!vm.firstReceiveAddress.isEmpty)
  }

  @Test func `tabs switch without validating`() {
    let vm = Self.wizard()
    vm.openCosigner(2)
    #expect(vm.currentCosignerIndex == 2)
    #expect(vm.cosignerErrors.isEmpty)
    #expect(vm.visitedCosigners == [0, 2])
  }

  // MARK: - Changing the cosigner count

  @Test func `back and next keep what was entered`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    vm.cosignerLabels[0] = "Alice"
    vm.goBack()
    vm.goToNext()
    #expect(vm.currentStep == .cosignerImport)
    #expect(vm.cosignerXpubs[0] == Self.keys[0].xpub)
    #expect(vm.cosignerLabels[0] == "Alice")
  }

  @Test func `resizing appends and drops from the end`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    Self.fill(vm, 2)
    vm.currentCosignerIndex = 2

    vm.totalCosigners = 5
    vm.resizeCosigners()
    #expect(vm.cosignerXpubs.count == 5)
    #expect(vm.cosignerLabels[3...] == ["Cosigner 4", "Cosigner 5"])
    #expect(vm.cosignerDerivationPaths[4] == "m/48'/1'/0'/2'")
    #expect(vm.cosignerXpubs[2] == Self.keys[2].xpub)

    vm.totalCosigners = 2
    vm.resizeCosigners()
    #expect(vm.cosignerXpubs == [Self.keys[0].xpub, ""])
    #expect(vm.cosignerLabels.count == 2)
    #expect(vm.currentCosignerIndex == 1, "The open cosigner stays in range")
  }

  @Test func `lowering the count reports filled cosigners only`() {
    let vm = Self.wizard()
    #expect(vm.filledCosignersDropped(byReducingTo: 1).isEmpty)
    vm.cosignerLabels[2] = "Carol"
    #expect(vm.filledCosignersDropped(byReducingTo: 1).isEmpty, "A label alone is not filled")
    vm.cosignerFingerprints[2] = "e3870581"
    #expect(vm.filledCosignersDropped(byReducingTo: 2) == [2])
    vm.cosignerXpubs[1] = Self.keys[1].xpub
    #expect(vm.filledCosignersDropped(byReducingTo: 1) == [1, 2])
    #expect(vm.filledCosignersDropped(byReducingTo: 3).isEmpty)
  }

  // MARK: - Changing the network

  @Test func `only mainnet and A test network cross key formats`() {
    #expect(SetupWizardViewModel.crossesKeyFormat(from: .mainnet, to: .testnet4))
    #expect(SetupWizardViewModel.crossesKeyFormat(from: .signet, to: .mainnet))
    #expect(!SetupWizardViewModel.crossesKeyFormat(from: .testnet4, to: .signet))
    #expect(!SetupWizardViewModel.crossesKeyFormat(from: .testnet3, to: .testnet4))
  }

  @Test func `crossing to mainnet clears keys and keeps labels`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    vm.cosignerLabels[0] = "Alice"
    vm.goToNextCosigner()
    vm.goToNextCosigner()
    #expect(vm.hasEnteredKeys)
    #expect(!vm.cosignerErrors.isEmpty)

    vm.changeNetwork(to: .mainnet)
    #expect(vm.network == .mainnet)
    #expect(!vm.hasEnteredKeys)
    #expect(vm.cosignerXpubs == ["", "", ""])
    #expect(vm.cosignerFingerprints == ["", "", ""])
    #expect(vm.cosignerDerivationPaths.allSatisfy { $0 == "m/48'/0'/0'/2'" })
    #expect(vm.cosignerLabels[0] == "Alice")
    #expect(vm.cosignerErrors.isEmpty)
  }

  @Test func `moving between test networks keeps keys`() {
    let vm = Self.wizard()
    Self.fill(vm, 0)
    vm.changeNetwork(to: .signet)
    #expect(vm.cosignerXpubs[0] == Self.keys[0].xpub)
    #expect(vm.cosignerFingerprints[0] == Self.keys[0].fingerprint)
  }

  /// A closed local port, so nothing leaves the machine
  private static func useUnreachableElectrumServer(_ vm: SetupWizardViewModel) {
    vm.electrumHost = "127.0.0.1"
    vm.electrumPort = "1"
  }
}

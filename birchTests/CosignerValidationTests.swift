@testable import birch
import Foundation
import Testing

@MainActor
struct CosignerValidationTests {
  @Test func validFingerprint() {
    let vm = SetupWizardViewModel()
    #expect(vm.validateFingerprint("73c5da0a") == nil)
    #expect(vm.validateFingerprint("AABBCCDD") == nil)
    #expect(vm.validateFingerprint("00000000") == nil)
  }

  @Test func fingerprintTooShort() {
    let vm = SetupWizardViewModel()
    let error = vm.validateFingerprint("73c5da")
    #expect(error != nil)
    #expect(error?.contains("8") == true)
  }

  @Test func fingerprintTooLong() {
    let vm = SetupWizardViewModel()
    let error = vm.validateFingerprint("73c5da0a1b")
    #expect(error != nil)
  }

  @Test func fingerprintNonHex() {
    let vm = SetupWizardViewModel()
    let error = vm.validateFingerprint("73c5dazz")
    #expect(error != nil)
    #expect(error?.contains("hex") == true)
  }

  @Test func emptyFingerprint() {
    let vm = SetupWizardViewModel()
    let error = vm.validateFingerprint("")
    #expect(error != nil)
  }

  @Test func validTestnetXpub() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    let error = vm.validateCosignerXpub(
      "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
      at: 0
    )
    #expect(error == nil)
  }

  @Test func rejectMainnetXpubOnTestnet() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    let error = vm.validateCosignerXpub(
      "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz",
      at: 0
    )
    #expect(error != nil)
    #expect(error?.contains("tpub") == true)
  }

  @Test func rejectDuplicateXpub() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    let xpub = "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ"
    vm.cosignerXpubs = [xpub, ""]

    let error = vm.validateCosignerXpub(xpub, at: 1)
    #expect(error != nil)
    #expect(error?.contains("Duplicate") == true)
  }

  @Test func rejectEmptyXpub() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    let error = vm.validateCosignerXpub("", at: 0)
    #expect(error != nil)
  }

  // MARK: - Extended Public Key Structure

  private static let tpub1 =
    "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ"
  private static let tpub2 =
    "tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP"

  /// A cosigner field must hold exactly one key. Text that starts with a valid
  /// tpub and then carries descriptor syntax would add a second, hidden key to
  /// the wallet if it were spliced into the descriptor.
  @Test func rejectXpubWithInjectedSecondKey() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    let injected = "\(Self.tpub1)/0/*,[aabbccdd/48'/1'/0'/2']\(Self.tpub2)"
    #expect(vm.validateCosignerXpub(injected, at: 0) != nil)
  }

  @Test func rejectXpubWithBadChecksum() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    // Last character changed (Q -> R)
    let corrupted = String(Self.tpub1.dropLast()) + "R"
    #expect(vm.validateCosignerXpub(corrupted, at: 0) != nil)
  }

  @Test func rejectTruncatedXpub() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    #expect(vm.validateCosignerXpub(String(Self.tpub1.dropLast(10)), at: 0) != nil)
    #expect(vm.validateCosignerXpub("tpubA", at: 0) != nil)
  }

  /// A SLIP132 Vpub and the tpub it converts to (the same key).
  private static let vpub =
    "Vpub5kv6Y3xqGFyhZQyCz8LzaSwVzAJLJTvHcUewWAhrLRRRjZeYs53qrfspVEBKZw6rvwGy8Z1ef7e7Vzsu3BLF6MkjFXWnLpmftKQT1Eub5Cf"
  private static let vpubAsTpub =
    "tpubDE4AYPPuhwTk7ENvANSMNU84wRecxjikg4e1WFHE4a6fxsNogCqnA7zzxyDoXp93JeyWNViXEKnkqaysaCrZRnTZDLYXnmbt7zrGxWYc3Mx"

  @Test func acceptVpubCosigner() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    #expect(vm.validateCosignerXpub(Self.vpub, at: 0) == nil)
  }

  @Test func acceptXpubWithSurroundingWhitespace() throws {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = ["", ""]

    let padded = "  \(Self.tpub1)\n"
    #expect(vm.validateCosignerXpub(padded, at: 0) == nil)

    // The descriptor is built from the key alone
    let withPadding = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: [
        (xpub: padded, fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
        (xpub: Self.tpub2, fingerprint: "0f056943", derivationPath: "m/48'/1'/0'/2'"),
      ],
      network: .testnet4,
      isChange: false
    )
    let withoutPadding = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: [
        (xpub: Self.tpub1, fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
        (xpub: Self.tpub2, fingerprint: "0f056943", derivationPath: "m/48'/1'/0'/2'"),
      ],
      network: .testnet4,
      isChange: false
    )
    #expect(withPadding == withoutPadding)
  }

  @Test func rejectDuplicateAcrossFormats() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.cosignerXpubs = [Self.vpub, ""]

    let error = vm.validateCosignerXpub(Self.vpubAsTpub, at: 1)
    #expect(error != nil)
    #expect(error?.contains("Duplicate") == true)
  }

  // MARK: - Key Placement (BIP48 depth and last step)

  /// Keys that decode correctly but do not sit at m/48'/coin'/0'/2'. The first is
  /// a real account-level key (descriptor vector #17). The rest are the descriptor
  /// vector #13 key (depth 4, last step 2') re-encoded with its depth or last-step
  /// field changed; the key material is untouched.
  private static let keysOffTheBIP48Path: [(name: String, xpub: String)] = [
    ("single-sig account key, depth 3, last step 0'",
     "tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh"),
    ("depth 4, last step 1' (nested segwit script type)",
     "tpubDFS7QGevX3YHN1stvEwMdMtM5dB74oDTFGjuyqc7MVVSqa4HgZke1R79Pc1jw6dWs6HGBBXLMMxwwezcuVftj9VG4FeuDsoMPb3KRfWhjgd"),
    ("depth 4, last step 2 (not hardened)",
     "tpubDFS7QGenBP1KEHR6YkZYvhqwuwHMcbecK9hvYtWvjbMQ7jcKavWfdoYZnXmSumJzTLCQG6QgR3hotdqJ81YNTpizoyi8wp85KWd93zJeCkc"),
    ("depth 5, last step 2'",
     "tpubDHKFG4AwjMDHGLLLVCACx2iepbeaWRAdFi8CrEHGonKirZE14aF9AuPwRR9AfEYuSh6WMrfZXNoofjSVEmZUyrjuFKxeNNtc3sozzEFXicz"),
    ("depth 3, last step 2'",
     "tpubDDYyYV8uJjsHYo5QRDEgKmByE9ph6xwj7usQ6WXwTubuzjLNz1ETbYEjvGbVBMjyZJED5ik91JPgJnTsW42ts2Y362JnyiJCQR96tDRr1yD"),
    ("depth 0, last step 2'",
     "tpubD7uZy8aqfprHyVC1KErPPMtwqV5rzncNvDVBxvuwT6XChzVws9iSEVVwfYmxxYXajCvmAWs1EBmVGMzwtyk1gnEEr4q1tiQawE8kjBfLo8Q"),
  ]

  @Test func acceptKeyAtBIP48Path() {
    // Testnet: tpub and SLIP132 Vpub, both depth 4 with a last step of 2'
    #expect(SetupWizardViewModel.validateXpub(Self.tpub1, for: .testnet4) == nil)
    #expect(SetupWizardViewModel.validateXpub(Self.vpub, for: .testnet4) == nil)
    #expect(SetupWizardViewModel.validateXpub(Self.tpub1, for: .signet) == nil)

    // Mainnet (descriptor vector #3)
    let mainnetKey = "xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw"
    #expect(SetupWizardViewModel.validateXpub(mainnetKey, for: .mainnet) == nil)
  }

  @Test func rejectKeyNotAtBIP48Path() {
    for (name, xpub) in Self.keysOffTheBIP48Path {
      let error = SetupWizardViewModel.validateXpub(xpub, for: .testnet4)
      #expect(error != nil, "\(name) should be rejected")
      #expect(error?.contains("m/48'/1'/0'/2'") == true, "\(name): unexpected message '\(error ?? "nil")'")

      // The cosigner entry screen goes through the same check
      let vm = SetupWizardViewModel()
      vm.network = .testnet4
      vm.cosignerXpubs = ["", ""]
      #expect(vm.validateCosignerXpub(xpub, at: 0) != nil, "\(name) should be rejected on entry")
    }
  }

  @Test func rejectMainnetKeyNotAtBIP48Path() {
    // Account-level key (depth 3, last step 0')
    let accountKey = "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz"
    let accountError = SetupWizardViewModel.validateXpub(accountKey, for: .mainnet)
    #expect(accountError?.contains("m/48'/0'/0'/2'") == true)
    #expect(accountError?.contains("3 steps") == true)
    #expect(accountError?.contains("last step of 0'") == true)

    // Master public key (depth 0)
    let masterKey = "Zpub6vZyhw1ShkEwP45J3TumYQietzUhSMreYW7k4sCza1iYaH9LrzR3inCtQ91szWGaMYWVNy74YBE9n1gmPHBzq2wEFGR83SMcFGuAbGkfiwg"
    #expect(SetupWizardViewModel.validateXpub(masterKey, for: .mainnet)?.contains("0 steps") == true)
  }

  /// Only for a key that is already part of a saved wallet (see CosignerEditTests).
  @Test func placementCheckCanBeSkippedForKeyAlreadySaved() {
    for (name, xpub) in Self.keysOffTheBIP48Path {
      #expect(
        SetupWizardViewModel.validateXpub(xpub, for: .testnet4, checkingPlacement: false) == nil,
        "\(name) is still a valid extended public key"
      )
    }
    // Skipping placement never skips the structural checks
    #expect(SetupWizardViewModel.validateXpub("tpubA", for: .testnet4, checkingPlacement: false) != nil)
  }

  /// The wizard builds descriptors only from cosigners that pass every check,
  /// even when the list was filled in without going through the entry screen.
  @Test func wizardBuildsDescriptorsOnlyFromStandardCosigners() {
    func wizard(_ change: (SetupWizardViewModel) -> Void) -> SetupWizardViewModel {
      let vm = SetupWizardViewModel()
      vm.network = .testnet4
      vm.requiredSignatures = 2
      vm.totalCosigners = 2
      vm.initializeCosigners()
      vm.cosignerXpubs = [Self.tpub1, Self.tpub2]
      vm.cosignerFingerprints = ["73c5da0a", "0f056943"]
      change(vm)
      vm.currentStep = .cosignerImport
      vm.goToNext()
      return vm
    }

    let standard = wizard { _ in }
    #expect(standard.currentStep == .walletName)
    #expect(standard.externalDescriptor.contains("[0f056943/48'/1'/0'/2']\(Self.tpub2)/0/*"))

    let rejected: [(name: String, vm: SetupWizardViewModel, message: String)] = [
      ("key off the BIP48 path",
       wizard { $0.cosignerXpubs[1] = Self.keysOffTheBIP48Path[0].xpub }, "m/48'/1'/0'/2'"),
      ("account 1 path", wizard { $0.cosignerDerivationPaths[1] = "m/48'/1'/1'/2'" }, "account 0"),
      ("mainnet path", wizard { $0.cosignerDerivationPaths[1] = "m/48'/0'/0'/2'" }, "mainnet"),
      ("non-BIP48 path", wizard { $0.cosignerDerivationPaths[1] = "m/84'/1'/0'" }, "BIP48"),
      ("bad fingerprint", wizard { $0.cosignerFingerprints[1] = "0f05694z" }, "hex"),
      ("duplicate key", wizard { $0.cosignerXpubs[1] = Self.tpub1 }, "Duplicate"),
    ]

    for (name, vm, message) in rejected {
      #expect(vm.currentStep == .cosignerImport, "\(name): the wizard must not advance")
      #expect(vm.externalDescriptor.isEmpty && vm.internalDescriptor.isEmpty, "\(name): no descriptor may be built")
      #expect(vm.errorMessage?.contains("Cosigner 2") == true, "\(name): '\(vm.errorMessage ?? "nil")'")
      #expect(vm.errorMessage?.contains(message) == true, "\(name): '\(vm.errorMessage ?? "nil")'")
    }
  }

  // MARK: - Derivation Path Network Validation

  @Test func validTestnetDerivationPath() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    #expect(vm.validateDerivationPath("m/48'/1'/0'/2'") == nil)
  }

  @Test func validMainnetDerivationPath() {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    #expect(vm.validateDerivationPath("m/48'/0'/0'/2'") == nil)
  }

  @Test func rejectTestnetPathOnMainnet() {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    let error = vm.validateDerivationPath("m/48'/1'/0'/2'")
    #expect(error != nil)
    let lower = error?.lowercased() ?? ""
    #expect(lower.contains("testnet"))
    #expect(lower.contains("mainnet"))
  }

  @Test func rejectMainnetPathOnTestnet() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    let error = vm.validateDerivationPath("m/48'/0'/0'/2'")
    #expect(error != nil)
    let lower = error?.lowercased() ?? ""
    #expect(lower.contains("mainnet"))
    #expect(lower.contains("testnet"))
  }

  @Test func rejectNonZeroAccountOnTestnet() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    let error = vm.validateDerivationPath("m/48'/1'/1'/2'")
    #expect(error != nil)
    #expect(error?.contains("account 0") == true)
  }

  @Test func rejectNonZeroAccountOnMainnet() {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    let error = vm.validateDerivationPath("m/48'/0'/5'/2'")
    #expect(error != nil)
    #expect(error?.contains("account 0") == true)
  }

  @Test func rejectInvalidBIP48Format() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    // Wrong script type
    #expect(vm.validateDerivationPath("m/48'/1'/0'/1'") != nil)
    // Missing hardened
    #expect(vm.validateDerivationPath("m/48/1/0/2") != nil)
    // Wrong purpose
    #expect(vm.validateDerivationPath("m/44'/1'/0'/2'") != nil)
    // Empty
    #expect(vm.validateDerivationPath("") != nil)
  }

  @Test func cosignerInfoValidation() {
    let valid = CosignerInfo(
      label: "Test",
      xpub: "tpubDFH9dgzveyD8",
      fingerprint: "73c5da0a",
      derivationPath: "m/48'/1'/0'/2'",
      orderIndex: 0
    )
    #expect(valid.isValidFingerprint)

    let invalidFP = CosignerInfo(
      label: "Test",
      xpub: "tpubDFH9dgzveyD8",
      fingerprint: "73c5da",
      derivationPath: "m/48'/1'/0'/2'",
      orderIndex: 0
    )
    #expect(!invalidFP.isValidFingerprint)
  }
}

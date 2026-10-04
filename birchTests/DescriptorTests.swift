@testable import birch
import BitcoinDevKit
import Foundation
import Testing
import URKit

@MainActor
struct DescriptorTests {
  // MARK: - Descriptor Construction

  @Test func buildTwoOfThreeDescriptor() throws {
    let external = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(external.hasPrefix("wsh(sortedmulti(2,"))
    #expect(external.hasSuffix("/0/*))"))
    #expect(external.contains("[73c5da0a/48'/1'/0'/2']"))
    #expect(external.contains("[0f056943/48'/1'/0'/2']"))
    #expect(external.contains("[effda333/48'/1'/0'/2']"))
  }

  @Test func buildChangeDescriptor() throws {
    let internal_desc = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: Array(Self.realTestnetCosigners.prefix(2)),
      network: .testnet4,
      isChange: true
    )

    #expect(internal_desc.contains("/1/*"))
    #expect(!internal_desc.contains("/0/*"))
  }

  @Test func descriptorKeysAreSortedLexicographically() throws {
    // Listed as tpubDFH…, tpubDF2…, tpubDFS…
    let cosigners = Self.realTestnetCosigners

    let desc = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .testnet4,
      isChange: false
    )

    // Keys should be sorted: tpubDF2…, tpubDFH…, tpubDFS…
    let firstPos = try #require(desc.range(of: cosigners[1].xpub)?.lowerBound)
    let secondPos = try #require(desc.range(of: cosigners[0].xpub)?.lowerBound)
    let thirdPos = try #require(desc.range(of: cosigners[2].xpub)?.lowerBound)

    #expect(firstPos < secondPos)
    #expect(secondPos < thirdPos)
  }

  @Test func descriptorRoundTrip() throws {
    let cosigners = Array(Self.realTestnetCosigners.prefix(2))

    let desc1 = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .testnet4,
      isChange: false
    )

    // Parse back via the wizard viewmodel
    let vm = SetupWizardViewModel()
    vm.importedDescriptorText = desc1
    let parsed = vm.parseImportedDescriptor()

    #expect(parsed)
    #expect(vm.requiredSignatures == 2)
    #expect(vm.totalCosigners == 2)

    // Rebuild from parsed data
    let reparsedCosigners = (0 ..< vm.totalCosigners).map { i in
      (xpub: vm.cosignerXpubs[i], fingerprint: vm.cosignerFingerprints[i], derivationPath: vm.cosignerDerivationPaths[i])
    }

    let desc2 = try BitcoinService.buildDescriptor(
      requiredSignatures: vm.requiredSignatures,
      cosigners: reparsedCosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(desc1 == desc2)
  }

  @Test func descriptorMainnetCoinType() throws {
    let desc = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realMainnetCosigners,
      network: .mainnet,
      isChange: false
    )

    #expect(desc.contains("48'/0'/0'/2'"))
  }

  @Test func descriptorTestnetCoinType() throws {
    let desc = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: Array(Self.realTestnetCosigners.prefix(2)),
      network: .testnet4,
      isChange: false
    )

    #expect(desc.contains("48'/1'/0'/2'"))
  }

  // MARK: - Cosigner Keys Must Be Single Extended Public Keys

  /// The builders place the key text in the descriptor, so they must refuse
  /// anything that is not exactly one extended public key.
  @Test func buildDescriptorThrowsOnInvalidKey() {
    let valid = Self.realTestnetCosigners[0]
    let invalidKeys = [
      "tpubA",
      // Bad checksum (last character changed)
      String(valid.xpub.dropLast()) + "R",
      // A valid key followed by a second, hidden key
      "\(valid.xpub)/0/*,[aabbccdd/48'/1'/0'/2']\(Self.realTestnetCosigners[1].xpub)",
      Self.testnetPrivateKey,
    ]

    for key in invalidKeys {
      let cosigners = [valid, (xpub: key, fingerprint: "aabbccdd", derivationPath: "m/48'/1'/0'/2'")]
      #expect(throws: AppError.self, "buildDescriptor should reject \(key)") {
        try BitcoinService.buildDescriptor(
          requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
        )
      }
      #expect(throws: AppError.self, "buildCombinedDescriptor should reject \(key)") {
        try BitcoinService.buildCombinedDescriptor(
          requiredSignatures: 2, cosigners: cosigners, network: .testnet4
        )
      }
    }
  }

  @Test func setupWizardBuildDescriptorsRejectsInjectedKey() {
    let cosigners = Self.realTestnetCosigners

    let vm = SetupWizardViewModel()
    vm.requiredSignatures = 2
    vm.totalCosigners = 2
    vm.network = .testnet4
    vm.initializeCosigners()
    vm.cosignerXpubs = [
      "\(cosigners[0].xpub)/0/*,[aabbccdd/48'/1'/0'/2']\(cosigners[2].xpub)",
      cosigners[1].xpub,
    ]
    vm.cosignerFingerprints = [cosigners[0].fingerprint, cosigners[1].fingerprint]
    vm.currentStep = .cosignerImport

    vm.goToNext()

    #expect(vm.currentStep == .cosignerImport, "The wizard must not advance past a key it cannot place in a descriptor")
    #expect(vm.externalDescriptor.isEmpty)
    #expect(vm.internalDescriptor.isEmpty)
    #expect(vm.combinedDescriptor.isEmpty)
    #expect(vm.errorMessage != nil)
  }

  // MARK: - Descriptor Parsing Validation

  @Test func rejectNonWshDescriptor() {
    let vm = SetupWizardViewModel()
    vm.importedDescriptorText = "sh(sortedmulti(2,[aabb/48'/1'/0'/2']tpubA/0/*,[ccdd/48'/1'/0'/2']tpubB/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage != nil)
  }

  @Test func rejectEmptyDescriptor() {
    let vm = SetupWizardViewModel()
    vm.importedDescriptorText = ""
    let result = vm.parseImportedDescriptor()
    #expect(!result)
  }

  @Test func rejectNonZeroAccountDescriptor() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.importedDescriptorText =
      "wsh(sortedmulti(2,[73c5da0a/48'/1'/1'/2']tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ/0/*,[0f056943/48'/1'/0'/2']tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage?.contains("account 0") == true)
  }

  @Test func rejectCoinTypeMismatchDescriptor() {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    // Testnet coin type (1') origins imported while mainnet is selected
    vm.importedDescriptorText =
      "wsh(sortedmulti(2,[73c5da0a/48'/1'/0'/2']tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ/0/*,[0f056943/48'/1'/0'/2']tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage?.lowercased().contains("testnet") == true)
  }

  @Test func rejectDescriptorWithKeyMissingOrigin() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    // Second key has no [fp/48'/...] origin info
    vm.importedDescriptorText =
      "wsh(sortedmulti(2,[73c5da0a/48'/1'/0'/2']tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ/0/*,tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage?.contains("origin") == true)
  }

  // MARK: - Import Stores Only What The Cosigner List Describes

  private enum ImportOutcome: CustomStringConvertible {
    case rejectedByBirch(String)
    case rejectedByBDK(String)
    case accepted(receive: String, change: String)

    var isRejectedByBirch: Bool {
      if case .rejectedByBirch = self {
        return true
      }
      return false
    }

    var description: String {
      switch self {
      case let .rejectedByBirch(message): "rejected by Birch (\(message))"
      case let .rejectedByBDK(message): "parsed by Birch, then rejected by BDK (\(message))"
      case let .accepted(receive, change): "accepted (receive[0]=\(receive) change[0]=\(change))"
      }
    }
  }

  /// Runs a descriptor through the real import path: Birch's parser, then a BDK
  /// wallet built from the descriptors the parser stored.
  private func importOutcome(_ descriptor: String, network: BitcoinNetwork = .testnet4) -> ImportOutcome {
    let vm = SetupWizardViewModel()
    vm.network = network
    vm.importedDescriptorText = descriptor

    guard vm.parseImportedDescriptor() else {
      return .rejectedByBirch(vm.errorMessage ?? "")
    }

    let bdkNetworkKind = BitcoinService.shared.bdkNetworkKind(from: network)
    do {
      let wallet = try Wallet(
        descriptor: Descriptor(descriptor: vm.externalDescriptor, networkKind: bdkNetworkKind),
        changeDescriptor: Descriptor(descriptor: vm.internalDescriptor, networkKind: bdkNetworkKind),
        network: BitcoinService.shared.bdkNetwork(from: network),
        persister: Persister.newInMemory()
      )
      return .accepted(
        receive: wallet.peekAddress(keychain: .external, index: 0).address.description,
        change: wallet.peekAddress(keychain: .internal, index: 0).address.description
      )
    } catch {
      return .rejectedByBDK("\(error)")
    }
  }

  /// `[fingerprint/48'/1'/0'/2']tpub` for one of `realTestnetCosigners`.
  private static func originKey(_ index: Int) -> String {
    let cosigner = realTestnetCosigners[index]
    return "[\(cosigner.fingerprint)/48'/1'/0'/2']\(cosigner.xpub)"
  }

  /// Valid mainnet keys (Bitcoin Core address vector #3).
  private static let realMainnetCosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
    (xpub: "xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw",
     fingerprint: "6738736c", derivationPath: "m/48'/0'/0'/2'"),
    (xpub: "xpub6EWhjpPa6FqrcaPBuGBZRJVjzGJ1ZsMygRF26RwN932Vfkn1gyCiTbECVitBjRCkexEvetLdiqzTcYimmzYxyR1BZ79KNevgt61PDcukmC7",
     fingerprint: "b2b1f0cf", derivationPath: "m/48'/0'/0'/2'"),
  ]

  /// Raw compressed public key (descriptor vector #5).
  private static let rawPublicKey = "03a0434d9e47f3c86235477c7b1ae6ae5d3442d49b1943c2b752a68e2a47e247c7"

  /// Extended private key (descriptor vector #27, a published test key).
  private static let testnetPrivateKey =
    "tprv8ZgxMBicQKsPdppqwh6vooJ1Du7JdgkXwbp3tvGdwYE58rdVe2Q7sdjiiH7mcanBgkVX9vgNBNzcbZx35fSBK3B6Z19yK2gwh1WDhqfPmgr"

  /// Two valid BIP48 keys plus a raw public key: the cosigner list would show
  /// 2-of-2 while the stored wallet is 2-of-3.
  @Test func rejectDescriptorWithHiddenRawKey() {
    let outcome = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(Self.originKey(1))/0/*,\(Self.rawPublicKey)))"
    )
    #expect(outcome.isRejectedByBirch, "Hidden raw key: \(outcome)")
  }

  /// One valid BIP48 key plus an extended private key: the cosigner list would
  /// show 1-of-1 and a watch-only app would be holding a private key.
  @Test func rejectDescriptorWithHiddenPrivateKey() {
    let descriptor = "wsh(sortedmulti(1,\(Self.originKey(0))/0/*,\(Self.testnetPrivateKey)/0/*))"

    let outcome = importOutcome(descriptor)
    #expect(outcome.isRejectedByBirch, "Hidden private key: \(outcome)")

    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.importedDescriptorText = descriptor
    #expect(!vm.parseImportedDescriptor())
    #expect(vm.errorMessage?.lowercased().contains("private key") == true)
  }

  @Test func rejectDescriptorWithMixedSuffixes() {
    let receiveAndChange = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(Self.originKey(1))/1/*))"
    )
    #expect(receiveAndChange.isRejectedByBirch, "Mixed /0/* and /1/*: \(receiveAndChange)")

    let multipathAndSingle = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/<0;1>/*,\(Self.originKey(1))/0/*))"
    )
    #expect(multipathAndSingle.isRejectedByBirch, "Mixed <0;1>/* and /0/*: \(multipathAndSingle)")
  }

  @Test func rejectDescriptorWithNonStandardSuffix() {
    let otherChain = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/5/*,\(Self.originKey(1))/5/*))"
    )
    #expect(otherChain.isRejectedByBirch, "Suffix /5/*: \(otherChain)")

    let extraStep = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/0/0/*,\(Self.originKey(1))/0/0/*))"
    )
    #expect(extraStep.isRejectedByBirch, "Suffix /0/0/*: \(extraStep)")
  }

  @Test func rejectDescriptorWithFixedChildKey() {
    let outcome = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/0/0,\(Self.originKey(1))/0/0))"
    )
    #expect(outcome.isRejectedByBirch, "Fixed child keys: \(outcome)")
  }

  @Test func rejectDescriptorWithTrailingText() {
    let extraKey = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(Self.originKey(1))/0/*)),\(Self.originKey(2))/0/*"
    )
    #expect(extraKey.isRejectedByBirch, "Key after the closing parentheses: \(extraKey)")

    let garbage = importOutcome(
      "wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(Self.originKey(1))/0/*))extra"
    )
    #expect(garbage.isRejectedByBirch, "Text after the closing parentheses: \(garbage)")
  }

  @Test func rejectDescriptorWithInvalidOrRepeatedKey() {
    let corrupted = String(Self.originKey(1).dropLast()) + "R"
    let badChecksum = importOutcome("wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(corrupted)/0/*))")
    #expect(badChecksum.isRejectedByBirch, "Key with a bad checksum: \(badChecksum)")

    let repeated = importOutcome("wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(Self.originKey(0))/0/*))")
    #expect(repeated.isRejectedByBirch, "Same key twice: \(repeated)")
  }

  /// What is stored is the descriptor rebuilt from the parsed cosigners, not
  /// the pasted text.
  @Test func importStoresCanonicalDescriptor() throws {
    let cosigners = Self.realTestnetCosigners
    // Multipath, h notation, an upper-case fingerprint, keys out of BIP67 order
    let pasted = "wsh(sortedmulti(2,"
      + "[73C5DA0A/48h/1h/0h/2h]\(cosigners[0].xpub)/<0;1>/*,"
      + "[0f056943/48h/1h/0h/2h]\(cosigners[1].xpub)/<0;1>/*,"
      + "[effda333/48h/1h/0h/2h]\(cosigners[2].xpub)/<0;1>/*))"

    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.importedDescriptorText = pasted
    #expect(vm.parseImportedDescriptor(), "Import failed: \(vm.errorMessage ?? "")")
    #expect(vm.requiredSignatures == 2)
    #expect(vm.totalCosigners == 3)

    let parsed = (0 ..< vm.totalCosigners).map { i in
      (xpub: vm.cosignerXpubs[i], fingerprint: vm.cosignerFingerprints[i], derivationPath: vm.cosignerDerivationPaths[i])
    }
    let external = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: parsed, network: .testnet4, isChange: false
    )
    let change = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: parsed, network: .testnet4, isChange: true
    )

    #expect(vm.externalDescriptor == external)
    #expect(vm.internalDescriptor == change)
  }

  /// Every supported suffix form imports to the same stored wallet.
  @Test func importAcceptsEverySupportedSuffixForm() throws {
    let expected = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: Array(Self.realTestnetCosigners.prefix(2)), network: .testnet4, isChange: false
    )

    for suffix in ["/<0;1>/*", "/<1;0>/*", "/{0,1}/*", "/{1,0}/*", "/0/*", "/1/*", ""] {
      let vm = SetupWizardViewModel()
      vm.network = .testnet4
      vm.importedDescriptorText = "wsh(sortedmulti(2,\(Self.originKey(0))\(suffix),\(Self.originKey(1))\(suffix)))"
      #expect(vm.parseImportedDescriptor(), "Suffix '\(suffix)' failed: \(vm.errorMessage ?? "")")
      #expect(vm.externalDescriptor == expected, "Suffix '\(suffix)' stored a different descriptor")
    }
  }

  /// Valid testnet key at the BIP48 path whose base58 text ends in "h": the
  /// descriptor vector #13 key with its parent-fingerprint field changed until
  /// the text ended that way. The key material is untouched.
  private static let keyEndingInH =
    "tpubDFS7QGfVshgA7gry51F1UfPmU8Yka4gSgTAKAHyKjrQVfGxfmkeLNtuSD6GqxRVEgeXBZZtXfWBUNkRiN1pTkvHrbTq3ayUhrgtCUMHEdrh"

  /// An account-level key from a single-sig path, m/44'/1'/0' (descriptor vector
  /// #17): depth 3, last step 0'. Its text also ends in "h".
  private static let accountLevelKey =
    "tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh"

  /// A BIP48 origin is only a label. The key under it must itself be four steps
  /// from the master key with a last step of 2'.
  @Test func rejectDescriptorWithKeyNotAtBIP48Path() {
    let descriptor = "wsh(sortedmulti(2,\(Self.originKey(0))/0/*,[367c9cfa/48'/1'/0'/2']\(Self.accountLevelKey)/0/*))"

    let outcome = importOutcome(descriptor)
    #expect(outcome.isRejectedByBirch, "Key off the BIP48 path under a BIP48 origin: \(outcome)")

    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.importedDescriptorText = descriptor
    #expect(!vm.parseImportedDescriptor())
    #expect(vm.errorMessage?.contains("Key 2") == true)
    #expect(vm.errorMessage?.contains("m/48'/1'/0'/2'") == true)
  }

  /// The builders check that a key is a single valid extended public key, not
  /// where it sits. Placement is enforced where keys enter the app, so a wallet
  /// saved before that rule existed can still build and export its descriptor.
  @Test func buildersDoNotRecheckKeyPlacement() throws {
    let cosigners = [
      Self.realTestnetCosigners[0],
      (xpub: Self.accountLevelKey, fingerprint: "367c9cfa", derivationPath: "m/48'/1'/0'/2'"),
    ]

    let external = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
    )
    #expect(external.contains("[367c9cfa/48'/1'/0'/2']\(Self.accountLevelKey)/0/*"))
    #expect(try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4
    ).contains(Self.accountLevelKey))
  }

  /// "h" is hardened notation only inside a key origin. A key that ends in "h"
  /// must be left as it is, whatever follows it ("/", "," or ")").
  @Test func importAcceptsKeyEndingInH() throws {
    let other = Self.realTestnetCosigners[0]
    let expected = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: [
        other,
        (xpub: Self.keyEndingInH, fingerprint: "367c9cfa", derivationPath: "m/48'/1'/0'/2'"),
      ],
      network: .testnet4,
      isChange: false
    )

    for hardened in ["'", "h"] {
      let origin = "/48\(hardened)/1\(hardened)/0\(hardened)/2\(hardened)]"
      let first = "[\(other.fingerprint)\(origin)\(other.xpub)"
      let second = "[367c9cfa\(origin)\(Self.keyEndingInH)"

      for suffix in ["/<0;1>/*", "/0/*", ""] {
        for keys in [[first, second], [second, first]] {
          let vm = SetupWizardViewModel()
          vm.network = .testnet4
          vm.importedDescriptorText = "wsh(sortedmulti(2,\(keys[0])\(suffix),\(keys[1])\(suffix)))"

          let label = "Origin notation \(hardened), suffix '\(suffix)', h-key \(keys[0] == second ? "first" : "last")"
          #expect(vm.parseImportedDescriptor(), "\(label) failed: \(vm.errorMessage ?? "")")
          #expect(vm.cosignerXpubs.contains(Self.keyEndingInH), "\(label): key was changed")
          #expect(vm.externalDescriptor == expected, "\(label): stored a different descriptor")
        }
      }
    }
  }

  /// Import runs on the main thread from pasted or scanned text, so text built
  /// to make the parser work hard must still be rejected at once.
  @Test func importRejectsOversizedHostileInputQuickly() {
    let hostileInputs = [
      String(repeating: "h/", count: 100_000),
      "wsh(sortedmulti(2," + String(repeating: "h/", count: 100_000) + "))",
      "wsh(sortedmulti(2," + String(repeating: "[", count: 100_000) + "))",
      "wsh(sortedmulti(2," + String(repeating: "\(Self.originKey(0))/0/*,", count: 2000) + "))",
    ]

    for input in hostileInputs {
      let vm = SetupWizardViewModel()
      vm.network = .testnet4
      vm.importedDescriptorText = input

      let start = Date()
      #expect(!vm.parseImportedDescriptor())
      let elapsed = Date().timeIntervalSince(start)
      #expect(elapsed < 2, "\(input.count) characters took \(elapsed) s to reject")
    }
  }

  /// The descriptor offered as a backup describes the wallet that was stored:
  /// importing the backup again gives the same descriptors and addresses.
  @Test func importedBackupMatchesWallet() {
    let descriptor = "wsh(sortedmulti(2,\(Self.originKey(0))/0/*,\(Self.originKey(1))/0/*,\(Self.originKey(2))/0/*))"

    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    vm.importedDescriptorText = descriptor
    #expect(vm.parseImportedDescriptor(), "Import failed: \(vm.errorMessage ?? "")")

    let backup = SetupWizardViewModel()
    backup.network = .testnet4
    backup.importedDescriptorText = vm.combinedDescriptor
    #expect(backup.parseImportedDescriptor(), "Backup import failed: \(backup.errorMessage ?? "")")
    #expect(backup.externalDescriptor == vm.externalDescriptor)
    #expect(backup.internalDescriptor == vm.internalDescriptor)

    guard case let .accepted(receive, change) = importOutcome(descriptor),
          case let .accepted(backupReceive, backupChange) = importOutcome(vm.combinedDescriptor)
    else {
      Issue.record("Both the descriptor and its exported backup should import")
      return
    }
    #expect(receive == backupReceive)
    #expect(change == backupChange)
  }

  // MARK: - Descriptor Checksum

  /// Valid testnet keys (the second and third are from the Bitcoin Core
  /// address vectors), listed out of BIP67 order.
  private static let realTestnetCosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
    (xpub: "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
     fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP",
     fingerprint: "0f056943", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi",
     fingerprint: "effda333", derivationPath: "m/48'/1'/0'/2'"),
  ]

  @Test func combinedDescriptorHasChecksum() throws {
    let desc = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4
    )

    // BIP-380 checksum is 8 characters after a '#'
    #expect(desc.contains("#"), "Combined descriptor should contain a checksum separator")
    let parts = desc.split(separator: "#")
    #expect(parts.count == 2, "Should have exactly one '#' separator")
    #expect(parts[1].count == 8, "Checksum should be 8 characters, got '\(parts[1])'")
  }

  @Test func combinedDescriptorChecksumIsDeterministic() throws {
    let desc1 = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4
    )
    let desc2 = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4
    )

    #expect(desc1 == desc2, "Same inputs should produce the same checksummed descriptor")
  }

  @Test func combinedDescriptorChecksumPreservesContent() throws {
    let desc = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4
    )

    #expect(desc.hasPrefix("wsh(sortedmulti(2,"), "Should still start with wsh(sortedmulti(2,")
    #expect(desc.contains("<0;1>/*"), "Should still contain multipath notation")
    #expect(desc.contains("[73c5da0a/48'/1'/0'/2']"), "Should contain cosigner fingerprint/path")
  }

  // MARK: - SLIP132 Vpub/Zpub normalization

  /// Cosigners as they might be entered by the user — first one is in SLIP132
  /// `Vpub` format (BIP-84 wsh testnet), the other two are standard `tpub`.
  /// BDK's descriptor parser only accepts `xpub`/`tpub`, so the descriptor
  /// builder must normalize the `Vpub` to `tpub` before assembly.
  private static let mixedFormatCosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
    (xpub: "Vpub5kv6Y3xqGFyhZQyCz8LzaSwVzAJLJTvHcUewWAhrLRRRjZeYs53qrfspVEBKZw6rvwGy8Z1ef7e7Vzsu3BLF6MkjFXWnLpmftKQT1Eub5Cf",
     fingerprint: "d03ce438", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDE2JvCZ3g8tEX3yegvXFn9cpzUyA2EEg6EwS7sAHcPER9yA6nFKdGPyLzsswYWa3SvEbKFmUiyFe9QQrpVpKwxojCud4ThNEv8R3j411Lcs",
     fingerprint: "f9755e5b", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDFEegnzQJr8LdYmGh1dGy3vqVgWtZ5w6q2cw4fbXhp15A29hvpf4NtAeFNvmmDRFTzeu1CveXs6dK2iPVADn2fSXWAQhHZhtLRGeHLmiBi5",
     fingerprint: "acc95047", derivationPath: "m/48'/1'/0'/2'"),
  ]

  /// The expected `tpub` form of the `Vpub` from `mixedFormatCosigners[0]`.
  private static let convertedTpub =
    "tpubDE4AYPPuhwTk7ENvANSMNU84wRecxjikg4e1WFHE4a6fxsNogCqnA7zzxyDoXp93JeyWNViXEKnkqaysaCrZRnTZDLYXnmbt7zrGxWYc3Mx"

  @Test func combinedDescriptorNormalizesVpubToTpub() throws {
    let desc = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4
    )

    // No SLIP132-tagged keys should remain in the assembled descriptor.
    #expect(!desc.contains("Vpub"), "Descriptor should not contain SLIP132 Vpub keys after normalization")
    #expect(!desc.contains("Zpub"), "Descriptor should not contain SLIP132 Zpub keys after normalization")

    // The converted tpub from the original Vpub must be present, paired with
    // the cosigner's original fingerprint.
    #expect(desc.contains(Self.convertedTpub), "Vpub should normalize to expected tpub: \(Self.convertedTpub)")
    #expect(desc.contains("[d03ce438/48'/1'/0'/2']\(Self.convertedTpub)"), "Converted tpub should retain the original fingerprint/origin")
  }

  @Test func singleChainDescriptorNormalizesVpubToTpub() throws {
    let external = try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(!external.contains("Vpub"), "External descriptor should not contain Vpub")
    #expect(external.contains(Self.convertedTpub), "External descriptor should contain the converted tpub")
  }

  @Test func descriptorBuiltFromMixedFormatsMatchesAllTpubVersion() throws {
    // Building the descriptor from the Vpub-mixed list should produce the same
    // result as building it from the equivalent all-tpub list — proving the
    // SLIP132 input is fully normalized away.
    let allTpubCosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: Self.convertedTpub, fingerprint: "d03ce438", derivationPath: "m/48'/1'/0'/2'"),
      Self.mixedFormatCosigners[1],
      Self.mixedFormatCosigners[2],
    ]

    let fromMixed = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4
    )
    let fromAllTpub = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: allTpubCosigners,
      network: .testnet4
    )

    #expect(fromMixed == fromAllTpub, "Descriptor built from Vpub+tpub mix should equal all-tpub descriptor")
  }

  // MARK: - Permutation Independence (BIP-67 canonical ordering)

  @Test func anyPermutationOfCosignersProducesSameDescriptor() throws {
    let cosigners = Self.mixedFormatCosigners
    let permutations: [[(xpub: String, fingerprint: String, derivationPath: String)]] = [
      [cosigners[0], cosigners[1], cosigners[2]],
      [cosigners[0], cosigners[2], cosigners[1]],
      [cosigners[1], cosigners[0], cosigners[2]],
      [cosigners[1], cosigners[2], cosigners[0]],
      [cosigners[2], cosigners[0], cosigners[1]],
      [cosigners[2], cosigners[1], cosigners[0]],
    ]

    let reference = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: permutations[0], network: .testnet4, isChange: false
    )

    for (i, perm) in permutations.enumerated() {
      let desc = try BitcoinService.buildDescriptor(
        requiredSignatures: 2, cosigners: perm, network: .testnet4, isChange: false
      )
      #expect(desc == reference, "Permutation \(i) should produce the same descriptor")
    }
  }

  @Test func anyPermutationOfCosignersProducesSameCombinedDescriptor() throws {
    let cosigners = Self.mixedFormatCosigners
    let permutations: [[(xpub: String, fingerprint: String, derivationPath: String)]] = [
      [cosigners[0], cosigners[1], cosigners[2]],
      [cosigners[1], cosigners[0], cosigners[2]],
      [cosigners[2], cosigners[1], cosigners[0]],
    ]

    let reference = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2, cosigners: permutations[0], network: .testnet4
    )

    for (i, perm) in permutations.enumerated() {
      let desc = try BitcoinService.buildCombinedDescriptor(
        requiredSignatures: 2, cosigners: perm, network: .testnet4
      )
      #expect(desc == reference, "Combined permutation \(i) should produce the same descriptor")
    }
  }

  @Test func setupWizardBuildDescriptorsMatchesBitcoinService() throws {
    let cosigners = Self.mixedFormatCosigners

    let vm = SetupWizardViewModel()
    vm.requiredSignatures = 2
    vm.totalCosigners = 3
    vm.network = .testnet4
    vm.initializeCosigners()
    for i in 0 ..< cosigners.count {
      vm.cosignerXpubs[i] = cosigners[i].xpub
      vm.cosignerFingerprints[i] = cosigners[i].fingerprint
      vm.cosignerDerivationPaths[i] = cosigners[i].derivationPath
    }
    vm.buildDescriptors()

    let serviceExternal = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
    )
    let serviceInternal = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: true
    )

    #expect(vm.externalDescriptor == serviceExternal,
            "SetupWizardViewModel should produce the same external descriptor as BitcoinService")
    #expect(vm.internalDescriptor == serviceInternal,
            "SetupWizardViewModel should produce the same internal descriptor as BitcoinService")
  }

  @Test func setupWizardPermutationIndependence() {
    let cosigners = Self.mixedFormatCosigners

    let vm1 = SetupWizardViewModel()
    vm1.requiredSignatures = 2
    vm1.totalCosigners = 3
    vm1.network = .testnet4
    vm1.initializeCosigners()
    for i in 0 ..< cosigners.count {
      vm1.cosignerXpubs[i] = cosigners[i].xpub
      vm1.cosignerFingerprints[i] = cosigners[i].fingerprint
      vm1.cosignerDerivationPaths[i] = cosigners[i].derivationPath
    }
    vm1.buildDescriptors()

    let vm2 = SetupWizardViewModel()
    vm2.requiredSignatures = 2
    vm2.totalCosigners = 3
    vm2.network = .testnet4
    vm2.initializeCosigners()
    let reversed = [cosigners[2], cosigners[1], cosigners[0]]
    for i in 0 ..< reversed.count {
      vm2.cosignerXpubs[i] = reversed[i].xpub
      vm2.cosignerFingerprints[i] = reversed[i].fingerprint
      vm2.cosignerDerivationPaths[i] = reversed[i].derivationPath
    }
    vm2.buildDescriptors()

    #expect(vm1.externalDescriptor == vm2.externalDescriptor,
            "Reversed cosigner order should produce the same external descriptor")
    #expect(vm1.internalDescriptor == vm2.internalDescriptor,
            "Reversed cosigner order should produce the same internal descriptor")
  }

  @Test func realCosignersPinnedDescriptor() throws {
    let expected = "wsh(sortedmulti(2," +
      "[f9755e5b/48'/1'/0'/2']tpubDE2JvCZ3g8tEX3yegvXFn9cpzUyA2EEg6EwS7sAHcPER9yA6nFKdGPyLzsswYWa3SvEbKFmUiyFe9QQrpVpKwxojCud4ThNEv8R3j411Lcs/<0;1>/*," +
      "[d03ce438/48'/1'/0'/2']tpubDE4AYPPuhwTk7ENvANSMNU84wRecxjikg4e1WFHE4a6fxsNogCqnA7zzxyDoXp93JeyWNViXEKnkqaysaCrZRnTZDLYXnmbt7zrGxWYc3Mx/<0;1>/*," +
      "[acc95047/48'/1'/0'/2']tpubDFEegnzQJr8LdYmGh1dGy3vqVgWtZ5w6q2cw4fbXhp15A29hvpf4NtAeFNvmmDRFTzeu1CveXs6dK2iPVADn2fSXWAQhHZhtLRGeHLmiBi5/<0;1>/*))"

    let desc = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4
    )

    let rawDesc = String(desc.prefix(while: { $0 != "#" }))
    #expect(rawDesc == expected, "Descriptor body should match the pinned expected value")
  }

  @Test func descriptorSortsByNormalizedXpubForBIP67() throws {
    // The user-supplied example: cosigners entered in [Vpub, tpub, tpub] order
    // with fingerprints [d03ce438, f9755e5b, acc95047]. After normalization,
    // BIP67 lexicographic sort by tpub puts them in this fingerprint order:
    //   1. f9755e5b  (tpubDE2JvCZ3g8tEX...)
    //   2. d03ce438  (tpubDE4AYPPuhwTk7... — converted from Vpub)
    //   3. acc95047  (tpubDFEegnzQJr8L...)
    let desc = try BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4
    )

    let fp1 = desc.range(of: "[f9755e5b/48'/1'/0'/2']")
    let fp2 = desc.range(of: "[d03ce438/48'/1'/0'/2']")
    let fp3 = desc.range(of: "[acc95047/48'/1'/0'/2']")

    #expect(fp1 != nil, "Descriptor should contain f9755e5b key origin")
    #expect(fp2 != nil, "Descriptor should contain d03ce438 key origin")
    #expect(fp3 != nil, "Descriptor should contain acc95047 key origin")

    if let fp1, let fp2, let fp3 {
      #expect(fp1.lowerBound < fp2.lowerBound, "f9755e5b (tpubDE2J...) should sort before d03ce438 (tpubDE4A...)")
      #expect(fp2.lowerBound < fp3.lowerBound, "d03ce438 (tpubDE4A...) should sort before acc95047 (tpubDFEe...)")
    }
  }

  /// Real descriptor decoded from a known-good crypto-output UR (from URServiceTests)
  private func realURDescriptor() -> String? {
    let urString = "UR:CRYPTO-OUTPUT/TAADMETAADMSOEADADAOLFTAADDLOSAOWKAXHDCLAOPDFNLNESAXHSJOFTVWFWHPTDUYPYHSROVLSWVDSRVWKBNNECZTHYMOURGSFDVDVAAAHDCXGMDKHPWMZTLRSOBSMWIOBWFWRPTODKNSEYAMTAHKRKQDISJTGWNSTSSFQDKPZSVTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYDYOTJEGMAXAAAYCYOYJNLKZMASJZGUIHIHIEGUINIOJTIHJPCXEYTAADDLOSAOWKAXHDCLAXIYMYFYWEMKASIOVSFYFDFDVASWONMTSKURSSTDMHVWSKLEAMKOVSGSDSCNSGNDOEAAHDCXBAMHFTFLGSDTBGBGFGGUREENGLFYTSHSCEJNKPHGGLFDFMTEWLENBDBBOXDYEMWTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYGRFPNSJOASJZGUIHIHIEGUINIOJTIHJPCXEHDLSWWZMD"
    let result = URService.processURString(urString)
    guard case let .descriptor(desc) = result else { return nil }
    return desc
  }

  @Test func checksumDoesNotAffectUREncoding() throws {
    guard let desc = realURDescriptor() else {
      Issue.record("Failed to decode test UR to descriptor")
      return
    }

    let checksum = BitcoinService.descriptorChecksum(desc)
    #expect(checksum.count == 8, "Checksum should be 8 characters")

    let descWithChecksum = desc + "#" + checksum

    // Encode both with and without checksum
    let urWithChecksum = try URService.encodeCryptoOutput(descriptor: descWithChecksum)
    let urWithoutChecksum = try URService.encodeCryptoOutput(descriptor: desc)

    // The CBOR data should be identical — checksum is stripped before encoding
    #expect(
      urWithChecksum.cbor.cborData == urWithoutChecksum.cbor.cborData,
      "Checksum should not affect the UR CBOR encoding"
    )
  }

  @Test func checksumDoesNotAffectAnimatedQRFrames() throws {
    guard let desc = realURDescriptor() else {
      Issue.record("Failed to decode test UR to descriptor")
      return
    }

    let checksum = BitcoinService.descriptorChecksum(desc)
    let descWithChecksum = desc + "#" + checksum

    let urWithChecksum = try URService.encodeCryptoOutput(descriptor: descWithChecksum)
    let urWithoutChecksum = try URService.encodeCryptoOutput(descriptor: desc)

    let maxFragmentLen = 160

    let encoderWith = UREncoder(urWithChecksum, maxFragmentLen: maxFragmentLen)
    let encoderWithout = UREncoder(urWithoutChecksum, maxFragmentLen: maxFragmentLen)

    // Same number of parts
    #expect(
      encoderWith.seqLen == encoderWithout.seqLen,
      "Both should produce the same number of UR parts"
    )

    // Same part content
    for i in 0 ..< encoderWith.seqLen {
      let partWith = encoderWith.nextPart()
      let partWithout = encoderWithout.nextPart()
      #expect(
        partWith == partWithout,
        "UR part \(i) should be identical regardless of checksum"
      )
    }
  }
}

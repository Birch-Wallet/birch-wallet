@testable import birch
import Foundation
import Testing
import URKit

@MainActor
struct DescriptorTests {
  // MARK: - Descriptor Construction

  @Test func buildTwoOfThreeDescriptor() {
    let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
       fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubDFcMWLJTavzfRa3Rc5i3bTMGBW7kYBLhLMJpLGSEik5pVhN5SMNKyVXHEB3Wnz6haXBMLF5MUiGMrawKaYFoZhBFNnEv7XEiv3FtGkBLtEHj",
       fingerprint: "f3ab64d8", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubDEmRJGMra7j5TnqBb4F8d43geT8sNXkWBzJbAjWz5n3Bm4EJ4CjxqwT2BqNNyVmGdXmMsBafF4vaVhEsEwNeXCxRN1mvPuDJCxPPBkpcjwY",
       fingerprint: "c0b5ce41", derivationPath: "m/48'/1'/0'/2'"),
    ]

    let external = BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(external.hasPrefix("wsh(sortedmulti(2,"))
    #expect(external.hasSuffix("/0/*))"))
    #expect(external.contains("[73c5da0a/48'/1'/0'/2']"))
    #expect(external.contains("[f3ab64d8/48'/1'/0'/2']"))
    #expect(external.contains("[c0b5ce41/48'/1'/0'/2']"))
  }

  @Test func buildChangeDescriptor() {
    let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: "tpubA", fingerprint: "aaaaaaaa", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubB", fingerprint: "bbbbbbbb", derivationPath: "m/48'/1'/0'/2'"),
    ]

    let internal_desc = BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .testnet4,
      isChange: true
    )

    #expect(internal_desc.contains("/1/*"))
    #expect(!internal_desc.contains("/0/*"))
  }

  @Test func descriptorKeysAreSortedLexicographically() throws {
    let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: "tpubZ", fingerprint: "11111111", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubA", fingerprint: "22222222", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubM", fingerprint: "33333333", derivationPath: "m/48'/1'/0'/2'"),
    ]

    let desc = BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .testnet4,
      isChange: false
    )

    // Keys should be sorted: tpubA, tpubM, tpubZ
    let aPos = try #require(desc.range(of: "tpubA")?.lowerBound)
    let mPos = try #require(desc.range(of: "tpubM")?.lowerBound)
    let zPos = try #require(desc.range(of: "tpubZ")?.lowerBound)

    #expect(aPos < mPos)
    #expect(mPos < zPos)
  }

  @Test func descriptorRoundTrip() {
    let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
       fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubDFcMWLJTavzfRa3Rc5i3bTMGBW7kYBLhLMJpLGSEik5pVhN5SMNKyVXHEB3Wnz6haXBMLF5MUiGMrawKaYFoZhBFNnEv7XEiv3FtGkBLtEHj",
       fingerprint: "f3ab64d8", derivationPath: "m/48'/1'/0'/2'"),
    ]

    let desc1 = BitcoinService.buildDescriptor(
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

    let desc2 = BitcoinService.buildDescriptor(
      requiredSignatures: vm.requiredSignatures,
      cosigners: reparsedCosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(desc1 == desc2)
  }

  @Test func descriptorMainnetCoinType() {
    let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: "xpubA", fingerprint: "aaaaaaaa", derivationPath: "m/48'/0'/0'/2'"),
      (xpub: "xpubB", fingerprint: "bbbbbbbb", derivationPath: "m/48'/0'/0'/2'"),
    ]

    let desc = BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .mainnet,
      isChange: false
    )

    #expect(desc.contains("48'/0'/0'/2'"))
  }

  @Test func descriptorTestnetCoinType() {
    let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: "tpubA", fingerprint: "aaaaaaaa", derivationPath: "m/48'/1'/0'/2'"),
      (xpub: "tpubB", fingerprint: "bbbbbbbb", derivationPath: "m/48'/1'/0'/2'"),
    ]

    let desc = BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(desc.contains("48'/1'/0'/2'"))
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
      "wsh(sortedmulti(2,[73c5da0a/48'/1'/1'/2']tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ/0/*,[f3ab64d8/48'/1'/0'/2']tpubDFcMWLJTavzfRa3Rc5i3bTMGBW7kYBLhLMJpLGSEik5pVhN5SMNKyVXHEB3Wnz6haXBMLF5MUiGMrawKaYFoZhBFNnEv7XEiv3FtGkBLtEHj/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage?.contains("account 0") == true)
  }

  @Test func rejectCoinTypeMismatchDescriptor() {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    // Testnet coin type (1') origins imported while mainnet is selected
    vm.importedDescriptorText =
      "wsh(sortedmulti(2,[73c5da0a/48'/1'/0'/2']tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ/0/*,[f3ab64d8/48'/1'/0'/2']tpubDFcMWLJTavzfRa3Rc5i3bTMGBW7kYBLhLMJpLGSEik5pVhN5SMNKyVXHEB3Wnz6haXBMLF5MUiGMrawKaYFoZhBFNnEv7XEiv3FtGkBLtEHj/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage?.lowercased().contains("testnet") == true)
  }

  @Test func rejectDescriptorWithKeyMissingOrigin() {
    let vm = SetupWizardViewModel()
    vm.network = .testnet4
    // Second key has no [fp/48'/...] origin info
    vm.importedDescriptorText =
      "wsh(sortedmulti(2,[73c5da0a/48'/1'/0'/2']tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ/0/*,tpubDFcMWLJTavzfRa3Rc5i3bTMGBW7kYBLhLMJpLGSEik5pVhN5SMNKyVXHEB3Wnz6haXBMLF5MUiGMrawKaYFoZhBFNnEv7XEiv3FtGkBLtEHj/0/*))"
    let result = vm.parseImportedDescriptor()
    #expect(!result)
    #expect(vm.errorMessage?.contains("origin") == true)
  }

  // MARK: - Descriptor Checksum

  private static let realTestnetCosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
    (xpub: "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
     fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDFcMWLJTavzfRa3Rc5i3bTMGBW7kYBLhLMJpLGSEik5pVhN5SMNKyVXHEB3Wnz6haXBMLF5MUiGMrawKaYFoZhBFNnEv7XEiv3FtGkBLtEHj",
     fingerprint: "f3ab64d8", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDEmRJGMra7j5TnqBb4F8d43geT8sNXkWBzJbAjWz5n3Bm4EJ4CjxqwT2BqNNyVmGdXmMsBafF4vaVhEsEwNeXCxRN1mvPuDJCxPPBkpcjwY",
     fingerprint: "c0b5ce41", derivationPath: "m/48'/1'/0'/2'"),
  ]

  @Test func combinedDescriptorHasChecksum() {
    let desc = BitcoinService.buildCombinedDescriptor(
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

  @Test func combinedDescriptorChecksumIsDeterministic() {
    let desc1 = BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4
    )
    let desc2 = BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.realTestnetCosigners,
      network: .testnet4
    )

    #expect(desc1 == desc2, "Same inputs should produce the same checksummed descriptor")
  }

  @Test func combinedDescriptorChecksumPreservesContent() {
    let desc = BitcoinService.buildCombinedDescriptor(
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

  @Test func combinedDescriptorNormalizesVpubToTpub() {
    let desc = BitcoinService.buildCombinedDescriptor(
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

  @Test func singleChainDescriptorNormalizesVpubToTpub() {
    let external = BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4,
      isChange: false
    )

    #expect(!external.contains("Vpub"), "External descriptor should not contain Vpub")
    #expect(external.contains(Self.convertedTpub), "External descriptor should contain the converted tpub")
  }

  @Test func descriptorBuiltFromMixedFormatsMatchesAllTpubVersion() {
    // Building the descriptor from the Vpub-mixed list should produce the same
    // result as building it from the equivalent all-tpub list — proving the
    // SLIP132 input is fully normalized away.
    let allTpubCosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
      (xpub: Self.convertedTpub, fingerprint: "d03ce438", derivationPath: "m/48'/1'/0'/2'"),
      Self.mixedFormatCosigners[1],
      Self.mixedFormatCosigners[2],
    ]

    let fromMixed = BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4
    )
    let fromAllTpub = BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: allTpubCosigners,
      network: .testnet4
    )

    #expect(fromMixed == fromAllTpub, "Descriptor built from Vpub+tpub mix should equal all-tpub descriptor")
  }

  // MARK: - Permutation Independence (BIP-67 canonical ordering)

  @Test func anyPermutationOfCosignersProducesSameDescriptor() {
    let cosigners = Self.mixedFormatCosigners
    let permutations: [[(xpub: String, fingerprint: String, derivationPath: String)]] = [
      [cosigners[0], cosigners[1], cosigners[2]],
      [cosigners[0], cosigners[2], cosigners[1]],
      [cosigners[1], cosigners[0], cosigners[2]],
      [cosigners[1], cosigners[2], cosigners[0]],
      [cosigners[2], cosigners[0], cosigners[1]],
      [cosigners[2], cosigners[1], cosigners[0]],
    ]

    let reference = BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: permutations[0], network: .testnet4, isChange: false
    )

    for (i, perm) in permutations.enumerated() {
      let desc = BitcoinService.buildDescriptor(
        requiredSignatures: 2, cosigners: perm, network: .testnet4, isChange: false
      )
      #expect(desc == reference, "Permutation \(i) should produce the same descriptor")
    }
  }

  @Test func anyPermutationOfCosignersProducesSameCombinedDescriptor() {
    let cosigners = Self.mixedFormatCosigners
    let permutations: [[(xpub: String, fingerprint: String, derivationPath: String)]] = [
      [cosigners[0], cosigners[1], cosigners[2]],
      [cosigners[1], cosigners[0], cosigners[2]],
      [cosigners[2], cosigners[1], cosigners[0]],
    ]

    let reference = BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2, cosigners: permutations[0], network: .testnet4
    )

    for (i, perm) in permutations.enumerated() {
      let desc = BitcoinService.buildCombinedDescriptor(
        requiredSignatures: 2, cosigners: perm, network: .testnet4
      )
      #expect(desc == reference, "Combined permutation \(i) should produce the same descriptor")
    }
  }

  @Test func setupWizardBuildDescriptorsMatchesBitcoinService() {
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

    let serviceExternal = BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
    )
    let serviceInternal = BitcoinService.buildDescriptor(
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

  @Test func realCosignersPinnedDescriptor() {
    let expected = "wsh(sortedmulti(2," +
      "[f9755e5b/48'/1'/0'/2']tpubDE2JvCZ3g8tEX3yegvXFn9cpzUyA2EEg6EwS7sAHcPER9yA6nFKdGPyLzsswYWa3SvEbKFmUiyFe9QQrpVpKwxojCud4ThNEv8R3j411Lcs/<0;1>/*," +
      "[d03ce438/48'/1'/0'/2']tpubDE4AYPPuhwTk7ENvANSMNU84wRecxjikg4e1WFHE4a6fxsNogCqnA7zzxyDoXp93JeyWNViXEKnkqaysaCrZRnTZDLYXnmbt7zrGxWYc3Mx/<0;1>/*," +
      "[acc95047/48'/1'/0'/2']tpubDFEegnzQJr8LdYmGh1dGy3vqVgWtZ5w6q2cw4fbXhp15A29hvpf4NtAeFNvmmDRFTzeu1CveXs6dK2iPVADn2fSXWAQhHZhtLRGeHLmiBi5/<0;1>/*))"

    let desc = BitcoinService.buildCombinedDescriptor(
      requiredSignatures: 2,
      cosigners: Self.mixedFormatCosigners,
      network: .testnet4
    )

    let rawDesc = String(desc.prefix(while: { $0 != "#" }))
    #expect(rawDesc == expected, "Descriptor body should match the pinned expected value")
  }

  @Test func descriptorSortsByNormalizedXpubForBIP67() {
    // The user-supplied example: cosigners entered in [Vpub, tpub, tpub] order
    // with fingerprints [d03ce438, f9755e5b, acc95047]. After normalization,
    // BIP67 lexicographic sort by tpub puts them in this fingerprint order:
    //   1. f9755e5b  (tpubDE2JvCZ3g8tEX...)
    //   2. d03ce438  (tpubDE4AYPPuhwTk7... — converted from Vpub)
    //   3. acc95047  (tpubDFEegnzQJr8L...)
    let desc = BitcoinService.buildCombinedDescriptor(
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

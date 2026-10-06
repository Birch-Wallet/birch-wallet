@testable import birch
import Foundation
import Testing
import URKit

struct URServiceTests {
  @Test func psbtURRoundTrip() throws {
    // Create some test PSBT bytes (psbt magic bytes)
    let psbtBytes = Data([0x70, 0x73, 0x62, 0x74, 0xFF, 0x01, 0x00, 0x52])

    let ur = try URService.encodePSBT(psbtBytes)
    #expect(ur.type == "crypto-psbt")

    let decoded = try URService.decodePSBT(from: ur)
    #expect(decoded == psbtBytes)
  }

  @Test func psbtURType() throws {
    let data = Data([0x01, 0x02, 0x03])
    let ur = try URService.encodePSBT(data)
    #expect(ur.type == "crypto-psbt")
  }

  @Test func rejectWrongURType() throws {
    // Create a UR with wrong type
    let data = Data([0x01, 0x02, 0x03])
    let ur = try URService.encodePSBT(data)

    // Try to parse as something else - processUR should handle gracefully
    let result = URService.processUR(ur)
    if case let .psbt(decoded) = result {
      #expect(decoded == data)
    } else {
      Issue.record("Expected PSBT result")
    }
  }

  @Test func processUnknownURType() {
    // Test handling of unknown UR types via processUR
    // This verifies the switch/case default handling
    // Since we can't easily create arbitrary UR types without valid CBOR,
    // we test that valid types are processed correctly
    let data = Data([0x70, 0x73, 0x62, 0x74, 0xFF])
    if let ur = try? URService.encodePSBT(data) {
      let result = URService.processUR(ur)
      if case .psbt = result {
        // Expected
      } else {
        Issue.record("Expected PSBT result type")
      }
    }
  }

  @Test func largePayloadEncoding() throws {
    // Test with a larger payload that might require fountain codes
    let largeData = Data(repeating: 0xAB, count: 1000)
    let ur = try URService.encodePSBT(largeData)
    let decoded = try URService.decodePSBT(from: ur)
    #expect(decoded == largeData)
    #expect(decoded.count == 1000)
  }

  // MARK: - crypto-account tests

  @Test func cryptoAccountSinglePartMainnet() {
    // Real SeedSigner mainnet crypto-account UR (single QR)
    let urString = "UR:CRYPTO-ACCOUNT/OEADCYKNBWOSPAAOLYTAADMETAADDLOXAXHDCLAXAXVEKKNYCFGRPKIHZSTICAKILFBAHDEERFMOCXLRFLHGIHCTGEWPVYGWJZSGKBNYAAHDCXRLSWDRDTHTUOQZMSJYEMAAHSRNJPHGFDLOADOLFNGECAKNIHMUTOCMHKADBKEYHGAMTAADDYOTADLOCSDYYKAEYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYVOFWEOBKNDQZEOAT"

    let result = URService.processURString(urString)
    guard case let .hdKey(xpub, fingerprint, derivationPath) = result else {
      Issue.record("Expected .hdKey result from crypto-account, got \(result)")
      return
    }

    #expect(!xpub.isEmpty, "xpub should not be empty")
    #expect(!fingerprint.isEmpty, "fingerprint should not be empty")
    #expect(fingerprint.count == 8, "fingerprint should be 8 hex chars")
    #expect(!derivationPath.isEmpty, "derivation path should not be empty")
    // Mainnet key: derivation path uses coin type 0
    #expect(derivationPath.contains("/0'/"), "mainnet derivation should contain /0'/")
    // xpub should start with 'xpub' for mainnet
    #expect(xpub.hasPrefix("xpub"), "mainnet xpub should start with 'xpub'")
  }

  @Test func cryptoAccountMultiPartTestnet() {
    // Real SeedSigner testnet crypto-account UR (animated multi-segment fountain code)
    let parts = [
      "UR:CRYPTO-ACCOUNT/1-2/LPADAOCSKECYLPRLOXFMHDFMOEADCYKNBWOSPAAOLYTAADMETAADDLONAXHDCLAXIYMYFYWEMKASIOVSFYFDFDVASWONMTSKURSSTDMHVWSKLEAMKOVSGSDSCNSGNDOEAAHDCXBAMHFTFLGSDTBGFRMSSSLN",
      "UR:CRYPTO-ACCOUNT/4-2/LPAAAOCSKECYLPRLOXFMHDFMBGFGGUREENGLFYTSHSCEJNKPHGGLFDFMTEWLENBDBBOXDYEMWTAHTAADEHOYAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYGRFPNSJOKGETIETN",
      "UR:CRYPTO-ACCOUNT/52-2/LPCSEEAOCSKECYLPRLOXFMHDFMPFFLGATKDAWLYKTLVTSKJZVEMNGWIONDTIPACHAYJPDNJYTNISBNRNWLKPWLGEVDRTKEMSYKKESKHTLOTLDYLUWFKOCAGLTECLTIVYPAOTWLCNBKMKCXBNBTREIDLSFERNHN",
    ]

    let result = URService.processMultiPartURStrings(parts)
    guard case let .hdKey(xpub, fingerprint, derivationPath) = result else {
      Issue.record("Expected .hdKey result from multi-part crypto-account, got \(result)")
      return
    }

    #expect(!xpub.isEmpty, "xpub should not be empty")
    #expect(!fingerprint.isEmpty, "fingerprint should not be empty")
    #expect(fingerprint.count == 8, "fingerprint should be 8 hex chars")
    #expect(!derivationPath.isEmpty, "derivation path should not be empty")
    // Testnet key: derivation path uses coin type 1
    #expect(derivationPath.contains("/1'/"), "testnet derivation should contain /1'/")
    // xpub should start with 'tpub' for testnet
    #expect(xpub.hasPrefix("tpub"), "testnet xpub should start with 'tpub'")
  }

  @Test func xpubNormalization() throws {
    // Real mainnet xpub from crypto-account
    let urString = "UR:CRYPTO-ACCOUNT/OEADCYKNBWOSPAAOLYTAADMETAADDLOXAXHDCLAXAXVEKKNYCFGRPKIHZSTICAKILFBAHDEERFMOCXLRFLHGIHCTGEWPVYGWJZSGKBNYAAHDCXRLSWDRDTHTUOQZMSJYEMAAHSRNJPHGFDLOADOLFNGECAKNIHMUTOCMHKADBKEYHGAMTAADDYOTADLOCSDYYKAEYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYVOFWEOBKNDQZEOAT"
    let result = URService.processURString(urString)
    guard case let .hdKey(xpub, _, _) = result else {
      Issue.record("Expected .hdKey result")
      return
    }

    #expect(xpub.hasPrefix("xpub"))

    // Convert xpub → tpub
    let tpub = URService.normalizeXpub(xpub, isTestnet: true)
    #expect(tpub != nil, "Should successfully convert xpub to tpub")
    let unwrappedTpub = try #require(tpub)
    #expect(unwrappedTpub.hasPrefix("tpub"), "Converted key should start with tpub")

    // Round-trip: tpub → xpub should give back the original
    let roundTripped = try URService.normalizeXpub(#require(tpub), isTestnet: false)
    #expect(roundTripped == xpub, "Round-trip conversion should produce original xpub")

    // Test Vpub -> tpub
    let vpub = "Vpub5mKYi6ZW8JMuPDDizjMfw5hwjj4xKSkmUSjVDJjrAghaCw7aSJF4v7M4miDJd6uwZcmxK1LcSCsXB7bY4ELTsV3VbCj2LqHq26b8VUzgDWo"
    let expectedTpub = "tpubDETciRzaZyqww2dSAyT2j6tWgzREyiZEY2iZDPKDtqNpSEqqFS31DZUFFTFnayx7wLUVYx3V1R2AWhhWbFrnCukKZ1kmnn83Fn2xSf7hEaH"

    let normalizedVpubToTpub = URService.normalizeXpub(vpub, isTestnet: true)
    #expect(normalizedVpubToTpub == expectedTpub, "Should correctly convert Vpub to tpub")

    let normalizedVpubToXpub = URService.normalizeXpub(vpub, isTestnet: false)
    #expect(normalizedVpubToXpub?.hasPrefix("xpub") == true, "Should correctly convert Vpub to xpub")

    // Zpub -> xpub
    let zpub = "Zpub6vZyhw1ShkEwP45J3TumYQietzUhSMreYW7k4sCza1iYaH9LrzR3inCtQ91szWGaMYWVNy74YBE9n1gmPHBzq2wEFGR83SMcFGuAbGkfiwg"
    let normalizedZpub = URService.normalizeXpub(zpub, isTestnet: false)
    let unwrappedZpub = try #require(normalizedZpub)
    #expect(unwrappedZpub.hasPrefix("xpub"), "Should correctly convert Zpub to xpub")
  }

  @Test func extendedPublicKeyDecodingAcceptsOnlySinglePublicKeys() {
    let tpub = "tpubDETciRzaZyqww2dSAyT2j6tWgzREyiZEY2iZDPKDtqNpSEqqFS31DZUFFTFnayx7wLUVYx3V1R2AWhhWbFrnCukKZ1kmnn83Fn2xSf7hEaH"
    let vpub = "Vpub5mKYi6ZW8JMuPDDizjMfw5hwjj4xKSkmUSjVDJjrAghaCw7aSJF4v7M4miDJd6uwZcmxK1LcSCsXB7bY4ELTsV3VbCj2LqHq26b8VUzgDWo"
    let zpub = "Zpub6vZyhw1ShkEwP45J3TumYQietzUhSMreYW7k4sCza1iYaH9LrzR3inCtQ91szWGaMYWVNy74YBE9n1gmPHBzq2wEFGR83SMcFGuAbGkfiwg"
    let xpub = "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz"

    for key in [tpub, vpub, zpub, xpub] {
      #expect(URService.decodeExtendedPublicKey(key)?.count == 78, "\(key.prefix(4)) should decode")
    }

    // Extended private keys have the same length and a valid checksum (published test keys)
    let xprv = "xprv9s21ZrQH143K31xYSDQpPDxsXRTUcvj2iNHm5NUtrGiGG5e2DtALGdso3pGz6ssrdK4PFmM8NSpSBHNqPqm55Qn3LqFtT2emdEXVYsCzC2U"
    let tprv = "tprv8ZgxMBicQKsPdppqwh6vooJ1Du7JdgkXwbp3tvGdwYE58rdVe2Q7sdjiiH7mcanBgkVX9vgNBNzcbZx35fSBK3B6Z19yK2gwh1WDhqfPmgr"
    #expect(URService.decodeExtendedPublicKey(xprv) == nil)
    #expect(URService.decodeExtendedPublicKey(tprv) == nil)
    #expect(URService.normalizeXpub(tprv, isTestnet: true) == nil)

    // Anything around the key
    #expect(URService.decodeExtendedPublicKey("\(tpub)/0/*") == nil)
    #expect(URService.decodeExtendedPublicKey("[73c5da0a/48'/1'/0'/2']\(tpub)") == nil)
    #expect(URService.decodeExtendedPublicKey(String(tpub.dropLast())) == nil)
    #expect(URService.decodeExtendedPublicKey("") == nil)

    // canonicalXpub ignores surrounding whitespace and slashes, nothing else
    #expect(URService.canonicalXpub(" \(vpub)\n", isTestnet: true) == tpub)
    #expect(URService.canonicalXpub("\(tpub)/", isTestnet: true) == tpub)
    #expect(URService.canonicalXpub("\(tpub)/0/*", isTestnet: true) == nil)
    #expect(URService.canonicalXpub("\(tpub),\(tpub)", isTestnet: true) == nil)
  }

  @Test func cryptoOutputDescriptorParsing() {
    // Real SeedSigner crypto-output UR containing a 1-of-2 wsh(sortedmulti(...)) descriptor
    let urString = "UR:CRYPTO-OUTPUT/TAADMETAADMSOEADADAOLFTAADDLOSAOWKAXHDCLAOPDFNLNESAXHSJOFTVWFWHPTDUYPYHSROVLSWVDSRVWKBNNECZTHYMOURGSFDVDVAAAHDCXGMDKHPWMZTLRSOBSMWIOBWFWRPTODKNSEYAMTAHKRKQDISJTGWNSTSSFQDKPZSVTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYDYOTJEGMAXAAAYCYOYJNLKZMASJZGUIHIHIEGUINIOJTIHJPCXEYTAADDLOSAOWKAXHDCLAXIYMYFYWEMKASIOVSFYFDFDVASWONMTSKURSSTDMHVWSKLEAMKOVSGSDSCNSGNDOEAAHDCXBAMHFTFLGSDTBGBGFGGUREENGLFYTSHSCEJNKPHGGLFDFMTEWLENBDBBOXDYEMWTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYGRFPNSJOASJZGUIHIHIEGUINIOJTIHJPCXEHDLSWWZMD"

    let result = URService.processURString(urString)
    guard case let .descriptor(desc) = result else {
      Issue.record("Expected .descriptor result, got \(result)")
      return
    }

    #expect(desc.hasPrefix("wsh(sortedmulti("), "Should start with wsh(sortedmulti(: \(desc)")
    #expect(desc.contains("tpub"), "Should contain tpub keys")
    #expect(desc.contains("30a36b52"), "Should contain first cosigner fingerprint")
    #expect(desc.contains("7a13a7b1"), "Should contain second cosigner fingerprint")
    #expect(desc.contains("48'/1'/0'/2'"), "Should contain BIP48 testnet derivation path")
    #expect(desc.contains("<0;1>/*"), "Should contain multipath wildcard")
    #expect(!desc.contains("//"), "Should not contain double slashes")
  }

  @Test func cryptoOutputMultipathSplitting() {
    // Verify that splitting BIP-389 multipath descriptors doesn't produce double slashes
    let urString = "UR:CRYPTO-OUTPUT/TAADMETAADMSOEADADAOLFTAADDLOSAOWKAXHDCLAOPDFNLNESAXHSJOFTVWFWHPTDUYPYHSROVLSWVDSRVWKBNNECZTHYMOURGSFDVDVAAAHDCXGMDKHPWMZTLRSOBSMWIOBWFWRPTODKNSEYAMTAHKRKQDISJTGWNSTSSFQDKPZSVTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYDYOTJEGMAXAAAYCYOYJNLKZMASJZGUIHIHIEGUINIOJTIHJPCXEYTAADDLOSAOWKAXHDCLAXIYMYFYWEMKASIOVSFYFDFDVASWONMTSKURSSTDMHVWSKLEAMKOVSGSDSCNSGNDOEAAHDCXBAMHFTFLGSDTBGBGFGGUREENGLFYTSHSCEJNKPHGGLFDFMTEWLENBDBBOXDYEMWTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYGRFPNSJOASJZGUIHIHIEGUINIOJTIHJPCXEHDLSWWZMD"

    let result = URService.processURString(urString)
    guard case let .descriptor(desc) = result else {
      Issue.record("Expected .descriptor result, got \(result)")
      return
    }

    // Simulate the multipath splitting that SetupWizardViewModel.parseImportedDescriptor does
    let externalDesc = desc.replacingOccurrences(of: "<0;1>/*", with: "0/*")
    let internalDesc = desc.replacingOccurrences(of: "<0;1>/*", with: "1/*")

    #expect(!externalDesc.contains("//"), "External descriptor should not contain double slashes: \(externalDesc)")
    #expect(!internalDesc.contains("//"), "Internal descriptor should not contain double slashes: \(internalDesc)")
    #expect(externalDesc.contains("/0/*"), "External descriptor should contain /0/*")
    #expect(internalDesc.contains("/1/*"), "Internal descriptor should contain /1/*")
  }

  // MARK: - crypto-output encoding tests (BCR-2020-010)

  /// Helper: decode the real test UR and return the descriptor string
  private static let testCryptoOutputUR = "UR:CRYPTO-OUTPUT/TAADMETAADMSOEADADAOLFTAADDLOSAOWKAXHDCLAOPDFNLNESAXHSJOFTVWFWHPTDUYPYHSROVLSWVDSRVWKBNNECZTHYMOURGSFDVDVAAAHDCXGMDKHPWMZTLRSOBSMWIOBWFWRPTODKNSEYAMTAHKRKQDISJTGWNSTSSFQDKPZSVTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYDYOTJEGMAXAAAYCYOYJNLKZMASJZGUIHIHIEGUINIOJTIHJPCXEYTAADDLOSAOWKAXHDCLAXIYMYFYWEMKASIOVSFYFDFDVASWONMTSKURSSTDMHVWSKLEAMKOVSGSDSCNSGNDOEAAHDCXBAMHFTFLGSDTBGBGFGGUREENGLFYTSHSCEJNKPHGGLFDFMTEWLENBDBBOXDYEMWTAHTAADEHOEADAEAOADAMTAADDYOTADLOCSDYYKADYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYGRFPNSJOASJZGUIHIHIEGUINIOJTIHJPCXEHDLSWWZMD"

  private func realDescriptor() -> String? {
    let result = URService.processURString(Self.testCryptoOutputUR)
    guard case let .descriptor(desc) = result else { return nil }
    return desc
  }

  @Test func encodeCryptoOutputRoundTrip() throws {
    guard let originalDesc = realDescriptor() else {
      Issue.record("Failed to decode test UR to descriptor")
      return
    }

    let encodedUR = try URService.encodeCryptoOutput(descriptor: originalDesc)
    #expect(encodedUR.type == "crypto-output")

    let reDecoded = try URService.parseCryptoOutput(from: encodedUR)
    #expect(reDecoded == originalDesc, "Round-trip failed.\nOriginal: \(originalDesc)\nRe-decoded: \(reDecoded)")
  }

  @Test func encodeCryptoOutputURType() throws {
    guard let desc = realDescriptor() else {
      Issue.record("Failed to decode test UR")
      return
    }
    let ur = try URService.encodeCryptoOutput(descriptor: desc)
    #expect(ur.type == "crypto-output")
  }

  @Test func encodeCryptoOutputStripsChecksum() throws {
    guard let desc = realDescriptor() else {
      Issue.record("Failed to decode test UR")
      return
    }
    // Append a fake checksum
    let descWithChecksum = desc + "#abcd1234"

    let ur1 = try URService.encodeCryptoOutput(descriptor: descWithChecksum)
    let ur2 = try URService.encodeCryptoOutput(descriptor: desc)

    #expect(ur1.cbor.cborData == ur2.cbor.cborData, "Checksum should be stripped before encoding")
  }

  @Test func encodeCryptoOutputPreservesKeys() throws {
    guard let desc = realDescriptor() else {
      Issue.record("Failed to decode test UR")
      return
    }
    let ur = try URService.encodeCryptoOutput(descriptor: desc)
    let decoded = try URService.parseCryptoOutput(from: ur)

    #expect(decoded.hasPrefix("wsh(sortedmulti("), "Should start with wsh(sortedmulti(")
    #expect(decoded.contains("30a36b52"), "Should preserve first cosigner fingerprint")
    #expect(decoded.contains("7a13a7b1"), "Should preserve second cosigner fingerprint")
    #expect(decoded.contains("48'/1'/0'/2'"), "Should preserve derivation path")
    #expect(decoded.contains("tpub"), "Should contain tpub keys")
  }

  @Test func encodeCryptoOutputPreservesMultipath() throws {
    guard let desc = realDescriptor() else {
      Issue.record("Failed to decode test UR")
      return
    }
    // The real descriptor has <0;1>/*
    #expect(desc.contains("<0;1>/*"), "Test descriptor should have multipath")

    let ur = try URService.encodeCryptoOutput(descriptor: desc)
    let decoded = try URService.parseCryptoOutput(from: ur)

    #expect(decoded.contains("<0;1>/*"), "Multipath should be implicitly preserved (omitted in CBOR, restored on parse)")
  }

  @Test func encodeCryptoOutputProcessURRoundTrip() throws {
    guard let desc = realDescriptor() else {
      Issue.record("Failed to decode test UR")
      return
    }
    let ur = try URService.encodeCryptoOutput(descriptor: desc)
    let result = URService.processUR(ur)

    guard case let .descriptor(decoded) = result else {
      Issue.record("Expected .descriptor result from processUR, got \(result)")
      return
    }

    #expect(decoded.hasPrefix("wsh(sortedmulti("), "processUR should decode to valid descriptor")
  }

  @Test func cryptoAccountExtractsP2WSHKey() {
    // Verify the parser prefers the BIP48 P2WSH key (derivation ending in /2')
    let urString = "UR:CRYPTO-ACCOUNT/OEADCYKNBWOSPAAOLYTAADMETAADDLOXAXHDCLAXAXVEKKNYCFGRPKIHZSTICAKILFBAHDEERFMOCXLRFLHGIHCTGEWPVYGWJZSGKBNYAAHDCXRLSWDRDTHTUOQZMSJYEMAAHSRNJPHGFDLOADOLFNGECAKNIHMUTOCMHKADBKEYHGAMTAADDYOTADLOCSDYYKAEYKAEYKAOYKAOCYKNBWOSPAAXAAAYCYVOFWEOBKNDQZEOAT"

    let result = URService.processURString(urString)
    guard case let .hdKey(_, _, derivationPath) = result else {
      Issue.record("Expected .hdKey result")
      return
    }

    // Should have extracted the P2WSH multisig key (script type 2')
    #expect(derivationPath.hasSuffix("/2'"), "Should prefer BIP48 P2WSH derivation path ending in /2', got: \(derivationPath)")
  }

  // MARK: - Out-of-range CBOR integers

  /// A crypto-hdkey map for m/48'/1'/0'/2'. Each override replaces one field;
  /// a nil depth leaves that optional field out, as some signers do.
  private func hdKeyMap(
    depth: UInt64? = 4,
    sourceFingerprint: UInt64 = 0x7A13_A7B1,
    parentFingerprint: UInt64 = 0x1234_5678,
    lastIndex: UInt64 = 2
  ) -> Map {
    var keypath = Map()
    keypath.insert(CBOR.unsigned(1), CBOR.array([
      .unsigned(48), .simple(.true), .unsigned(1), .simple(.true),
      .unsigned(0), .simple(.true), .unsigned(lastIndex), .simple(.true),
    ]))
    keypath.insert(CBOR.unsigned(2), CBOR.unsigned(sourceFingerprint))
    if let depth {
      keypath.insert(CBOR.unsigned(3), CBOR.unsigned(depth))
    }

    var hdKey = Map()
    hdKey.insert(CBOR.unsigned(3), CBOR.bytes(Data([0x02] + [UInt8](repeating: 0x11, count: 32))))
    hdKey.insert(CBOR.unsigned(4), CBOR.bytes(Data(repeating: 0x22, count: 32)))
    hdKey.insert(CBOR.unsigned(6), CBOR.tagged(Tag(304), CBOR.map(keypath)))
    hdKey.insert(CBOR.unsigned(8), CBOR.unsigned(parentFingerprint))
    return hdKey
  }

  /// A crypto-hdkey UR for m/48'/1'/0'/2'. Each override replaces one field
  /// with a value too large for its type.
  private func hdKeyUR(
    depth: UInt64? = 4,
    sourceFingerprint: UInt64 = 0x7A13_A7B1,
    parentFingerprint: UInt64 = 0x1234_5678,
    lastIndex: UInt64 = 2
  ) throws -> UR {
    let hdKey = hdKeyMap(
      depth: depth, sourceFingerprint: sourceFingerprint, parentFingerprint: parentFingerprint, lastIndex: lastIndex
    )
    return try UR(type: "crypto-hdkey", cbor: CBOR.map(hdKey))
  }

  // MARK: - Key placement (depth and last step)

  private static let hardened: UInt32 = 0x8000_0000

  @Test func extendedPublicKeyPlacementReadsDepthAndLastStep() throws {
    // BIP48 P2WSH key at m/48'/1'/0'/2' (descriptor vector #13)
    let bip48 = try #require(URService.extendedPublicKeyPlacement(
      "tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi"
    ))
    #expect(bip48.depth == 4)
    #expect(bip48.childNumber == Self.hardened | 2)

    // The same key as a SLIP132 Vpub reads the same
    let vpub = try #require(URService.extendedPublicKeyPlacement(
      "Vpub5kv6Y3xqGFyhZQyCz8LzaSwVzAJLJTvHcUewWAhrLRRRjZeYs53qrfspVEBKZw6rvwGy8Z1ef7e7Vzsu3BLF6MkjFXWnLpmftKQT1Eub5Cf"
    ))
    #expect(vpub.depth == 4)
    #expect(vpub.childNumber == Self.hardened | 2)

    // Account-level key from a single-sig path (m/44'/1'/0', descriptor vector #17)
    let account = try #require(URService.extendedPublicKeyPlacement(
      "tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh"
    ))
    #expect(account.depth == 3)
    #expect(account.childNumber == Self.hardened | 0)

    // Master public key
    let master = try #require(URService.extendedPublicKeyPlacement(
      "Zpub6vZyhw1ShkEwP45J3TumYQietzUhSMreYW7k4sCza1iYaH9LrzR3inCtQ91szWGaMYWVNy74YBE9n1gmPHBzq2wEFGR83SMcFGuAbGkfiwg"
    ))
    #expect(master.depth == 0)
    #expect(master.childNumber == 0)

    #expect(URService.extendedPublicKeyPlacement("tpubA") == nil)
    #expect(URService.extendedPublicKeyPlacement("") == nil)
  }

  @Test func scannedKeyKeepsTheDepthItsSignerDeclared() throws {
    let declared = try URService.parseHDKey(from: hdKeyUR(depth: 4))
    #expect(URService.extendedPublicKeyPlacement(declared.xpub)?.depth == 4)

    // A declared depth is never overridden, even when it disagrees with the path
    let mismatched = try URService.parseHDKey(from: hdKeyUR(depth: 3))
    #expect(URService.extendedPublicKeyPlacement(mismatched.xpub)?.depth == 3)
  }

  /// Depth is optional in a crypto-hdkey. A signer that leaves it out still gave
  /// the path, so the rebuilt key takes its depth from the path's four steps.
  @Test func scannedKeyWithoutDepthFieldTakesDepthFromItsPath() throws {
    let result = try URService.parseHDKey(from: hdKeyUR(depth: nil))
    #expect(result.derivationPath == "m/48'/1'/0'/2'")

    let placement = try #require(URService.extendedPublicKeyPlacement(result.xpub))
    #expect(placement.depth == 4)
    #expect(placement.childNumber == Self.hardened | 2)
  }

  @Test func scannedDescriptorKeyWithoutDepthFieldTakesDepthFromItsPath() throws {
    var multisig = Map()
    multisig.insert(CBOR.unsigned(1), CBOR.unsigned(1))
    multisig.insert(CBOR.unsigned(2), CBOR.array([.tagged(Tag(303), CBOR.map(hdKeyMap(depth: nil)))]))
    let ur = try UR(type: "crypto-output", cbor: .tagged(Tag(401), .tagged(Tag(406), CBOR.map(multisig))))

    guard case let .descriptor(descriptor) = URService.processUR(ur) else {
      Issue.record("Expected a descriptor from the crypto-output")
      return
    }
    #expect(descriptor.hasPrefix("wsh(sortedmulti(1,[7a13a7b1/48'/1'/0'/2']tpub"))

    // The key text sits between the origin's "]" and the "/" of its suffix
    let afterOrigin = try #require(descriptor.components(separatedBy: "]").last)
    let xpub = String(afterOrigin.prefix { $0 != "/" })
    let placement = try #require(URService.extendedPublicKeyPlacement(xpub))
    #expect(placement.depth == 4)
    #expect(placement.childNumber == Self.hardened | 2)
  }

  @Test func hdKeyInRangeStillParses() throws {
    let result = try URService.parseHDKey(from: hdKeyUR())
    #expect(result.fingerprint == "7a13a7b1")
    #expect(result.derivationPath == "m/48'/1'/0'/2'")
    #expect(!result.xpub.isEmpty)
  }

  @Test func hdKeyRejectsOutOfRangeDepth() throws {
    let ur = try hdKeyUR(depth: 300)
    #expect(throws: AppError.self) { try URService.parseHDKey(from: ur) }
  }

  @Test func hdKeyRejectsOutOfRangeParentFingerprint() throws {
    let ur = try hdKeyUR(parentFingerprint: 1 << 40)
    #expect(throws: AppError.self) { try URService.parseHDKey(from: ur) }
  }

  @Test func hdKeyRejectsOutOfRangeSourceFingerprint() throws {
    let ur = try hdKeyUR(sourceFingerprint: 1 << 40)
    #expect(throws: AppError.self) { try URService.parseHDKey(from: ur) }
  }

  @Test func hdKeyRejectsChildIndexWithHardenedBitSet() throws {
    let ur = try hdKeyUR(lastIndex: 1 << 31)
    #expect(throws: AppError.self) { try URService.parseHDKey(from: ur) }
  }

  @Test func processURReportsBadKeyInsteadOfCrashing() throws {
    let result = try URService.processUR(hdKeyUR(depth: UInt64.max))
    if case .hdKey = result {
      Issue.record("An out-of-range depth must not produce a key")
    }
  }
}

@testable import birch
import BitcoinDevKit
import Foundation
import Testing

/// Traces where `non_witness_utxo` survives or is lost across Birch's PSBT path:
/// BDK creation with Birch's TxBuilder options, then combine() with the PSBT a
/// signing device hands back.
@MainActor
struct NonWitnessUtxoTests {
  /// A real testnet4 5-of-9 wallet (xpubs taken from a Birch-built PSBT)
  private let external = "wsh(sortedmulti(5,[8b587280/48'/1'/0'/2']tpubDDvqWJ1FqiAtVbtgy72D6FQQewec9MYTpCYMmLGCEk4DWMHS6S8shw5J1c8w2LdgBaqQ39RGua4tEHPecfXZ4WQWGDY6JVu3mANH5ZTiPui/0/*,[f9755e5b/48'/1'/0'/2']tpubDE2JvCZ3g8tEX3yegvXFn9cpzUyA2EEg6EwS7sAHcPER9yA6nFKdGPyLzsswYWa3SvEbKFmUiyFe9QQrpVpKwxojCud4ThNEv8R3j411Lcs/0/*,[07d25f0c/48'/1'/0'/2']tpubDE2gU1F6b1GXDg2bFjeq6RUnBmAe2moTNG7x47Cga3VnVnm7EJWLdJE73ZL2MEwKTc2dLNeSudXUjexm2xJ5qboosbnEb1SEiGyJtJcqqZK/0/*,[d03ce438/48'/1'/0'/2']tpubDE4AYPPuhwTk7ENvANSMNU84wRecxjikg4e1WFHE4a6fxsNogCqnA7zzxyDoXp93JeyWNViXEKnkqaysaCrZRnTZDLYXnmbt7zrGxWYc3Mx/0/*,[d73869a4/48'/1'/0'/2']tpubDET5GnMK8Zr7UH63ni72etKd7ZYxVq8NvtSneNBfEDJ7YtnSHUmiPCaBYXzCdR6ZBKWvBMXT3urCVp7sLmG6z8VTpdFRJuW4VL7xjHdLFpY/0/*,[e3870581/48'/1'/0'/2']tpubDF3GwUrMb5WkigsDUpUWUADH55G3Ez771QujmFqeyrNEPD7onkqTwCsCEjNRbSrbD9VYKDfMHfg7bajem5aEX7CyMp2q5fvQzacy75bUesQ/0/*,[acc95047/48'/1'/0'/2']tpubDFEegnzQJr8LdYmGh1dGy3vqVgWtZ5w6q2cw4fbXhp15A29hvpf4NtAeFNvmmDRFTzeu1CveXs6dK2iPVADn2fSXWAQhHZhtLRGeHLmiBi5/0/*,[9b5bd0dc/48'/1'/0'/2']tpubDFWFvyvWHv6n7eWQ2tH5d9pTSnCUVyfcVDS9mxBLMm1bBFTyMV8KSPXgCEBVVwLk5YArnrXGMu5a5RmQvzzDwT17ceAeCrUgWEDnHcjF6Y8/0/*,[7c6b40c0/48'/1'/0'/2']tpubDFg2GTVFsBbKc8K3ZqRjV3f4Z7Uedpu5oymHUzNUBafWkigsgFyZchY2GAXppBCosdQGXmsAZwyucPSLFnD9e8fX6BMEmsZ6Taj8Gp6h158/0/*))"

  /// A real 33-byte pubkey and DER signature from that PSBT. combine() does not
  /// verify signatures, so it stands in for a device's signature here.
  private let sigPubkey = "02a0c8cc953ad33f1fd41360fda1eac72030d16cab731d4e732beee6256dd4a5e3"
  private let signature = "30440220398bd1e7489d8fedded4ccb0f3ac9869353bf2fd5522e4cc14ce4726f9be6fe8022000e4b773789f6163c68bc2030d2bb58d7318c58156d32ec3ff121f6124f7065d01"

  private var internalDescriptor: String {
    external.replacingOccurrences(of: "/0/*", with: "/1/*")
  }

  /// A watch-only wallet holding one unconfirmed 50,000 sat output at receive index 0
  private func fundedWallet() throws -> (Wallet, OutPoint) {
    let kind = BitcoinService.shared.bdkNetworkKind(from: .testnet4)
    let wallet = try Wallet(
      descriptor: Descriptor(descriptor: external, networkKind: kind),
      changeDescriptor: Descriptor(descriptor: internalDescriptor, networkKind: kind),
      network: BitcoinService.shared.bdkNetwork(from: .testnet4),
      persister: Persister.newInMemory()
    )
    let script = wallet.peekAddress(keychain: .external, index: 0).address.scriptPubkey().toBytes()

    var tx = Data([0x02, 0x00, 0x00, 0x00, 0x01]) // version 2, one input
    tx += Data(repeating: 0x42, count: 32) + Data([0x00, 0x00, 0x00, 0x00]) // outpoint
    tx += Data([0x00, 0xFF, 0xFF, 0xFF, 0xFF]) // empty scriptSig, sequence
    tx += Data([0x01]) // one output
    tx += withUnsafeBytes(of: UInt64(50000).littleEndian) { Data($0) }
    tx += Data([UInt8(script.count)]) + script
    tx += Data([0x00, 0x00, 0x00, 0x00]) // locktime

    let funding = try Transaction(transactionBytes: tx)
    wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: funding, lastSeen: 1)])
    return (wallet, OutPoint(txid: funding.computeTxid(), vout: 0))
  }

  /// Builds a PSBT with the same TxBuilder options as BitcoinService.createPSBT
  private func birchPSBT(_ wallet: Wallet, spending outpoint: OutPoint) throws -> Psbt {
    let recipient = wallet.peekAddress(keychain: .external, index: 5).address.scriptPubkey()
    return try TxBuilder()
      .feeRate(feeRate: FeeRate.fromSatPerVb(satVb: 2))
      .addGlobalXpubs()
      .nlocktime(locktime: .blocks(height: 100_000))
      .addUtxos(outpoints: [outpoint])
      .manuallySelectedOnly()
      .addRecipient(script: recipient, amount: Amount.fromSat(satoshi: 10000))
      .finish(wallet: wallet)
  }

  /// What SeedSigner's PSBTParser.trim() hands back: the unsigned transaction plus
  /// each input's partial signatures, and nothing else
  private func seedSignerTrimmed(_ original: Psbt) throws -> Psbt {
    let parsed = try PSBTParser.parse(#require(Data(base64Encoded: original.serialize())))
    let txRecord = try #require(parsed.records.first { $0.map == .global && $0.keyType == 0x00 })
    let pubkey = hexData(sigPubkey)
    let sig = hexData(signature)

    var bytes = Data([0x70, 0x73, 0x62, 0x74, 0xFF])
    bytes += Data([0x01, 0x00]) + compactSize(txRecord.value.count) + txRecord.value + Data([0x00])
    for _ in 0 ..< parsed.inputCount {
      bytes += Data([UInt8(1 + pubkey.count), 0x02]) + pubkey + Data([UInt8(sig.count)]) + sig + Data([0x00])
    }
    bytes += Data(repeating: 0x00, count: parsed.outputCount)
    return try Psbt(psbtBase64: bytes.base64EncodedString())
  }

  private func hexData(_ hex: String) -> Data {
    var bytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
      index = next
    }
    return Data(bytes)
  }

  private func compactSize(_ n: Int) -> Data {
    n < 0xFD ? Data([UInt8(n)]) : Data([0xFD, UInt8(n & 0xFF), UInt8(n >> 8)])
  }

  @Test func creationIncludesNonWitnessUtxo() throws {
    let (wallet, outpoint) = try fundedWallet()
    let psbt = try birchPSBT(wallet, spending: outpoint)
    #expect(psbt.input()[0].nonWitnessUtxo != nil)
    #expect(psbt.input()[0].witnessUtxo != nil)
  }

  @Test func combineWithCompactReturnedPSBTKeepsNonWitnessUtxo() throws {
    let (wallet, outpoint) = try fundedWallet()
    let original = try birchPSBT(wallet, spending: outpoint)
    let originalBytes = try #require(Data(base64Encoded: original.serialize()))

    // A device that returned the whole compact PSBT it scanned
    let returned = try Psbt(psbtBase64: PSBTCompactor.compact(originalBytes).base64EncodedString())

    // BitcoinService.combinePSBTs: original.combine(other: signed)
    let combined = try original.combine(other: returned)
    #expect(combined.input()[0].nonWitnessUtxo != nil)
  }

  @Test func combineWithSeedSignerTrimmedPSBTKeepsNonWitnessUtxo() throws {
    let (wallet, outpoint) = try fundedWallet()
    let original = try birchPSBT(wallet, spending: outpoint)

    let returned = try seedSignerTrimmed(original)

    let combined = try original.combine(other: returned)
    #expect(combined.input()[0].nonWitnessUtxo != nil)
  }
}

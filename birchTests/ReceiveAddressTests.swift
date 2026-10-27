@testable import birch
import BitcoinDevKit
import Foundation
import SwiftData
import Testing

/// Picking the receive address must not move the wallet's derivation index
/// unless the address it lands on was never revealed.
@MainActor
struct ReceiveAddressTests {
  // MARK: - Test Data Helpers

  private static let tpub =
    "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ"

  /// A fresh in-memory wallet with receive address #0 revealed, as loadWallet leaves it
  private static func makeWallet() throws -> Wallet {
    let kind = BitcoinService.shared.bdkNetworkKind(from: .testnet4)
    let wallet = try Wallet(
      descriptor: Descriptor(descriptor: "wpkh(\(tpub)/0/*)", networkKind: kind),
      changeDescriptor: Descriptor(descriptor: "wpkh(\(tpub)/1/*)", networkKind: kind),
      network: BitcoinService.shared.bdkNetwork(from: .testnet4),
      persister: Persister.newInMemory(),
    )
    _ = wallet.revealNextAddress(keychain: .external)
    return wallet
  }

  /// A cap far past every index these tests reach, for the tests about stepping
  private static let cap: UInt32 = 100

  private static func address(_ wallet: Wallet, _ index: UInt32) -> String {
    wallet.peekAddress(keychain: .external, index: index).address.description
  }

  // MARK: - Viewing does not move the index

  @Test func `repeated lookups do not advance revealed index`() throws {
    let wallet = try Self.makeWallet()
    for _ in 0 ..< 10 {
      let (info, didReveal) = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: [], maxIndex: Self.cap))
      #expect(info.index == 0)
      #expect(!didReveal)
    }
    #expect(wallet.derivationIndex(keychain: .external) == 0)
  }

  @Test func `skips taken addresses and reveals once`() throws {
    let wallet = try Self.makeWallet()
    let taken: Set<String> = [Self.address(wallet, 0), Self.address(wallet, 1)]

    let first = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: taken, maxIndex: Self.cap))
    #expect(first.info.index == 2)
    #expect(first.didReveal)
    #expect(wallet.derivationIndex(keychain: .external) == 2)

    let second = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: taken, maxIndex: Self.cap))
    #expect(second.info.index == 2)
    #expect(!second.didReveal)
    #expect(wallet.derivationIndex(keychain: .external) == 2)
  }

  // MARK: - Next Address steps by one

  @Test func `next address steps from the one shown`() throws {
    let wallet = try Self.makeWallet()
    // A reveal counter inflated by the old behaviour must not make the step jump
    _ = wallet.revealAddressesTo(keychain: .external, index: 12)

    let next = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 1, taken: [], maxIndex: Self.cap))
    #expect(next.info.index == 1)
    #expect(!next.didReveal)
    #expect(wallet.derivationIndex(keychain: .external) == 12)
  }

  @Test func `next address skips taken`() throws {
    let wallet = try Self.makeWallet()
    let taken: Set<String> = [Self.address(wallet, 1), Self.address(wallet, 2)]
    let next = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 1, taken: taken, maxIndex: Self.cap))
    #expect(next.info.index == 3)
    #expect(wallet.derivationIndex(keychain: .external) == 3)
  }

  // MARK: - Labeled addresses count as taken

  @Test func `labeled addresses are only this wallets non empty address labels`() throws {
    let schema = Schema([WalletLabel.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = ModelContext(container)
    let walletID = UUID()
    context.insert(WalletLabel(walletID: walletID, type: .addr, ref: "tb1qlabeled", label: "Invoice 42"))
    context.insert(WalletLabel(walletID: walletID, type: .addr, ref: "tb1qblank", label: "   "))
    context.insert(WalletLabel(walletID: walletID, type: .tx, ref: "sometxid", label: "Rent"))
    context.insert(WalletLabel(walletID: UUID(), type: .addr, ref: "tb1qotherwallet", label: "Other"))
    try context.save()

    #expect(LabelService.labeledAddresses(walletID: walletID, context: context) == ["tb1qlabeled"])
  }

  @Test func `labeled unused address is skipped`() throws {
    let wallet = try Self.makeWallet()
    // Address #0 has no transactions but was labeled, i.e. given to a payer
    let labeled: Set<String> = [Self.address(wallet, 0)]
    let (info, _) = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: labeled, maxIndex: Self.cap))
    #expect(info.index == 1)
  }

  // MARK: - Gap limit

  /// Pays `amount` sats to receive address `index`, as an unconfirmed transaction
  private static func fund(_ wallet: Wallet, index: UInt32, amount: UInt64 = 10000) throws {
    let script = wallet.peekAddress(keychain: .external, index: index).address.scriptPubkey().toBytes()
    var tx = Data([0x02, 0x00, 0x00, 0x00, 0x01]) // version 2, one input
    tx += Data(repeating: UInt8(index & 0xFF), count: 32) + Data([0x00, 0x00, 0x00, 0x00]) // outpoint
    tx += Data([0x00, 0xFF, 0xFF, 0xFF, 0xFF]) // empty scriptSig, sequence
    tx += Data([0x01]) // one output
    tx += withUnsafeBytes(of: amount.littleEndian) { Data($0) }
    tx += Data([UInt8(script.count)]) + script
    tx += Data([0x00, 0x00, 0x00, 0x00]) // locktime
    let funding = try Transaction(transactionBytes: tx)
    wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: funding, lastSeen: 1)])
  }

  @Test func `with nothing paid the cap is the gap minus one`() {
    #expect(BitcoinService.receiveIndexCap(lastUsed: nil, gap: 20) == 19)
  }

  @Test func `after a paid address the cap is that index plus the gap`() {
    #expect(BitcoinService.receiveIndexCap(lastUsed: 7, gap: 20) == 27)
  }

  @Test func `the cap never overflows and treats a gap below one as one`() {
    #expect(BitcoinService.receiveIndexCap(lastUsed: .max - 3, gap: 20) == .max)
    #expect(BitcoinService.receiveIndexCap(lastUsed: nil, gap: 0) == 0)
  }

  @Test func `the last used receive index comes from the wallets transactions`() throws {
    let wallet = try Self.makeWallet()
    #expect(BitcoinService.lastUsedReceiveIndex(in: wallet) == nil)
    try Self.fund(wallet, index: 7)
    try Self.fund(wallet, index: 3)
    #expect(BitcoinService.lastUsedReceiveIndex(in: wallet) == 7)
  }

  @Test func `the address at the cap is handed out`() throws {
    let wallet = try Self.makeWallet()
    // #0–#18 already handed out, with the cap at #19 (gap 20, nothing paid)
    let taken = Set((0 ..< 19).map { Self.address(wallet, UInt32($0)) })
    let last = try #require(BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: taken, maxIndex: 19))
    #expect(last.info.index == 19)
  }

  @Test func `nothing past the cap is handed out or revealed`() throws {
    let wallet = try Self.makeWallet()
    let taken = Set((0 ..< 20).map { Self.address(wallet, UInt32($0)) })
    #expect(BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: taken, maxIndex: 19) == nil)
    // Next Address from the address at the cap
    #expect(BitcoinService.availableReceiveAddress(in: wallet, from: 20, taken: [], maxIndex: 19) == nil)
    #expect(wallet.derivationIndex(keychain: .external) == 0)
  }

  @Test func `looking for the next address reveals nothing`() throws {
    let wallet = try Self.makeWallet()
    let next = try #require(BitcoinService.firstAvailableReceiveAddress(in: wallet, from: 5, taken: [], maxIndex: 19))
    #expect(next.index == 5)
    #expect(wallet.derivationIndex(keychain: .external) == 0)
  }

  @Test func `paying an address moves the cap on`() throws {
    let wallet = try Self.makeWallet()
    let gap = 20
    let before = BitcoinService.receiveIndexCap(lastUsed: BitcoinService.lastUsedReceiveIndex(in: wallet), gap: gap)
    #expect(BitcoinService.firstAvailableReceiveAddress(in: wallet, from: before + 1, taken: [], maxIndex: before) == nil)

    try Self.fund(wallet, index: 4)
    let after = BitcoinService.receiveIndexCap(lastUsed: BitcoinService.lastUsedReceiveIndex(in: wallet), gap: gap)
    #expect(after == 24)
    let next = try #require(BitcoinService.firstAvailableReceiveAddress(in: wallet, from: before + 1, taken: [], maxIndex: after))
    #expect(next.index == before + 1)
  }
}

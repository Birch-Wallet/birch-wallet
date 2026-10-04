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
      persister: Persister.newInMemory()
    )
    _ = wallet.revealNextAddress(keychain: .external)
    return wallet
  }

  private static func address(_ wallet: Wallet, _ index: UInt32) -> String {
    wallet.peekAddress(keychain: .external, index: index).address.description
  }

  // MARK: - Viewing does not move the index

  @Test func repeatedLookupsDoNotAdvanceRevealedIndex() throws {
    let wallet = try Self.makeWallet()
    for _ in 0 ..< 10 {
      let (info, didReveal) = BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: [])
      #expect(info.index == 0)
      #expect(!didReveal)
    }
    #expect(wallet.derivationIndex(keychain: .external) == 0)
  }

  @Test func skipsTakenAddressesAndRevealsOnce() throws {
    let wallet = try Self.makeWallet()
    let taken: Set<String> = [Self.address(wallet, 0), Self.address(wallet, 1)]

    let first = BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: taken)
    #expect(first.info.index == 2)
    #expect(first.didReveal)
    #expect(wallet.derivationIndex(keychain: .external) == 2)

    let second = BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: taken)
    #expect(second.info.index == 2)
    #expect(!second.didReveal)
    #expect(wallet.derivationIndex(keychain: .external) == 2)
  }

  // MARK: - Next Address steps by one

  @Test func nextAddressStepsFromTheOneShown() throws {
    let wallet = try Self.makeWallet()
    // A reveal counter inflated by the old behaviour must not make the step jump
    _ = wallet.revealAddressesTo(keychain: .external, index: 12)

    let next = BitcoinService.availableReceiveAddress(in: wallet, from: 1, taken: [])
    #expect(next.info.index == 1)
    #expect(!next.didReveal)
    #expect(wallet.derivationIndex(keychain: .external) == 12)
  }

  @Test func nextAddressSkipsTaken() throws {
    let wallet = try Self.makeWallet()
    let taken: Set<String> = [Self.address(wallet, 1), Self.address(wallet, 2)]
    let next = BitcoinService.availableReceiveAddress(in: wallet, from: 1, taken: taken)
    #expect(next.info.index == 3)
    #expect(wallet.derivationIndex(keychain: .external) == 3)
  }

  // MARK: - Labeled addresses count as taken

  @Test func labeledAddressesAreOnlyThisWalletsNonEmptyAddressLabels() throws {
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

  @Test func labeledUnusedAddressIsSkipped() throws {
    let wallet = try Self.makeWallet()
    // Address #0 has no transactions but was labeled, i.e. given to a payer
    let labeled: Set<String> = [Self.address(wallet, 0)]
    let (info, _) = BitcoinService.availableReceiveAddress(in: wallet, from: 0, taken: labeled)
    #expect(info.index == 1)
  }
}

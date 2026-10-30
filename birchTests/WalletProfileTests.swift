@testable import birch
import Foundation
import SwiftData
import Testing

struct WalletProfileTests {
  private func createTestContainer() throws -> ModelContainer {
    let schema = Schema([WalletProfile.self, CosignerInfo.self, ElectrumServer.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  @Test func `create and persist profile`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    let profile = WalletProfile(
      name: "Test Wallet",
      requiredSignatures: 2,
      totalCosigners: 3,
      externalDescriptor: "wsh(sortedmulti(2,...))",
      internalDescriptor: "wsh(sortedmulti(2,...))",
      network: .testnet4,
      isActive: true,
    )

    context.insert(profile)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<WalletProfile>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.name == "Test Wallet")
    #expect(fetched.first?.requiredSignatures == 2)
    #expect(fetched.first?.totalCosigners == 3)
    #expect(fetched.first?.isActive == true)
    #expect(fetched.first?.bitcoinNetwork == .testnet4)
  }

  @Test func `only one active wallet`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    let wallet1 = WalletProfile(
      name: "Wallet 1", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "wsh(...)", internalDescriptor: "wsh(...)",
      network: .testnet4, isActive: true,
    )
    let wallet2 = WalletProfile(
      name: "Wallet 2", requiredSignatures: 2, totalCosigners: 2,
      externalDescriptor: "wsh(...)", internalDescriptor: "wsh(...)",
      network: .testnet4, isActive: false,
    )

    context.insert(wallet1)
    context.insert(wallet2)
    try context.save()

    // Activate wallet 2, deactivate wallet 1
    wallet1.isActive = false
    wallet2.isActive = true
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<WalletProfile>())
    let active = fetched.filter(\.isActive)
    #expect(active.count == 1)
    #expect(active.first?.name == "Wallet 2")
  }

  @Test func `cascade delete cosigners`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    let wallet = WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 2,
      externalDescriptor: "wsh(...)", internalDescriptor: "wsh(...)",
      network: .testnet4, isActive: true,
    )
    context.insert(wallet)

    let cosigner1 = CosignerInfo(
      label: "Cosigner 1", xpub: "tpubA", fingerprint: "aaaaaaaa",
      derivationPath: "m/48'/1'/0'/2'", orderIndex: 0,
    )
    cosigner1.wallet = wallet
    context.insert(cosigner1)

    let cosigner2 = CosignerInfo(
      label: "Cosigner 2", xpub: "tpubB", fingerprint: "bbbbbbbb",
      derivationPath: "m/48'/1'/0'/2'", orderIndex: 1,
    )
    cosigner2.wallet = wallet
    context.insert(cosigner2)

    try context.save()

    // Verify cosigners exist
    let cosigners = try context.fetch(FetchDescriptor<CosignerInfo>())
    #expect(cosigners.count == 2)

    // Delete wallet
    context.delete(wallet)
    try context.save()

    // Cosigners should be cascade deleted
    let remaining = try context.fetch(FetchDescriptor<CosignerInfo>())
    #expect(remaining.count == 0)
  }

  @Test func `multisig description`() {
    let wallet = WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "", internalDescriptor: "",
      network: .testnet4,
    )
    #expect(wallet.multisigDescription == "2-of-3")
  }

  private func profile(addressGapLimit: Int = 20) -> WalletProfile {
    WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "", internalDescriptor: "",
      network: .testnet4, addressGapLimit: addressGapLimit,
    )
  }

  private func server(port: Int) -> ElectrumServer {
    ElectrumServer(name: "", host: "electrum.example.com", port: port, useSSL: true, network: .testnet4)
  }

  /// A stored port that is not a port number must not trap: every connection reads
  /// it, so a trap there would make the wallet impossible to open.
  @Test(arguments: [65536, 500_022, 0, -1, Int.max, Int.min])
  func `out of range port falls back to the default`(port: Int) {
    #expect(server(port: port).config.port == BitcoinNetwork.testnet4.defaultElectrumPort)
  }

  @Test func `A server's port is used when it is A port number`() {
    #expect(server(port: 1).config.port == 1)
    #expect(server(port: 12345).config.port == 12345)
    #expect(server(port: 65535).config.port == 65535)
  }

  // MARK: - Electrum server

  @Test func `A wallet uses its own server, then A public one, then none`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = profile()
    context.insert(wallet)
    #expect(wallet.electrumServerChoice == nil)
    #expect(wallet.electrumConfig == nil)

    let mempool = try #require(ElectrumServerCatalog.server(id: "testnet4.mempool"))
    wallet.setElectrumServer(.builtIn(mempool))
    #expect(wallet.electrumServerChoice == .builtIn(mempool))
    #expect(wallet.electrumConfig?.url == "ssl://testnet4.mempool.space:40002")

    let own = server(port: 50002)
    context.insert(own)
    wallet.setElectrumServer(.custom(own))
    #expect(wallet.electrumServerChoice == .custom(own))
    #expect(wallet.builtInElectrumServerID.isEmpty)
    #expect(wallet.electrumConfig?.url == "ssl://electrum.example.com:50002")

    wallet.setElectrumServer(nil)
    #expect(wallet.electrumServerChoice == nil)
  }

  /// The wallets on a deleted server are left with none, not moved to another
  @Test func `deleting A server leaves its wallets with none`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let own = server(port: 50002)
    context.insert(own)
    let first = profile()
    let second = profile()
    context.insert(first)
    context.insert(second)
    first.setElectrumServer(.custom(own))
    second.setElectrumServer(.custom(own))
    try context.save()
    #expect(own.wallets.count == 2)

    context.delete(own)
    try context.save()
    #expect(first.electrumServerChoice == nil)
    #expect(second.electrumServerChoice == nil)
    #expect(try context.fetch(FetchDescriptor<WalletProfile>()).count == 2)
  }

  /// A wallet made now has nothing to carry over; one saved before servers were
  /// shared reads false from the store until the migration runs
  @Test func `A new wallet needs no migration`() {
    #expect(profile().electrumServerMigrated)
  }

  /// New wallets scan 50 unused addresses past the last used one. A gap of 50 costs
  /// at most one more batch per keychain than 20 did.
  @Test func `new profile starts with a gap of 50`() {
    let wallet = WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "", internalDescriptor: "",
      network: .testnet4,
    )
    #expect(wallet.addressGapLimit == 50)
    #expect(wallet.scanGapLimit == 50)
  }

  /// The gap limit is converted to an unsigned count for every full scan and
  /// bounds the address list, so a stored value out of range must be held in.
  @Test func `scan gap limit stays within range`() {
    #expect(profile(addressGapLimit: 20).scanGapLimit == 20)
    #expect(profile(addressGapLimit: InputLimits.maxGapLimit).scanGapLimit == InputLimits.maxGapLimit)

    #expect(profile(addressGapLimit: 0).scanGapLimit == 1)
    #expect(profile(addressGapLimit: -1).scanGapLimit == 1)
    #expect(profile(addressGapLimit: Int.min).scanGapLimit == 1)
    #expect(profile(addressGapLimit: InputLimits.maxGapLimit + 1).scanGapLimit == InputLimits.maxGapLimit)
    #expect(profile(addressGapLimit: Int.max).scanGapLimit == InputLimits.maxGapLimit)
  }

  @Test func `multiple wallets switching`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    for i in 1 ... 3 {
      let wallet = WalletProfile(
        name: "Wallet \(i)", requiredSignatures: 2, totalCosigners: 3,
        externalDescriptor: "wsh(...\(i))", internalDescriptor: "wsh(...\(i))",
        network: .testnet4, isActive: i == 1,
      )
      context.insert(wallet)
    }
    try context.save()

    let wallets = try context.fetch(FetchDescriptor<WalletProfile>())
    #expect(wallets.count == 3)

    // Switch to wallet 3
    for w in wallets {
      w.isActive = (w.name == "Wallet 3")
    }
    try context.save()

    let active = wallets.filter(\.isActive)
    #expect(active.count == 1)
    #expect(active.first?.name == "Wallet 3")
  }
}

@testable import birch
import Foundation
import SwiftData
import Testing

struct WalletProfileTests {
  private func createTestContainer() throws -> ModelContainer {
    let schema = Schema([WalletProfile.self, CosignerInfo.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  @Test func createAndPersistProfile() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    let profile = WalletProfile(
      name: "Test Wallet",
      requiredSignatures: 2,
      totalCosigners: 3,
      externalDescriptor: "wsh(sortedmulti(2,...))",
      internalDescriptor: "wsh(sortedmulti(2,...))",
      network: .testnet4,
      isActive: true
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

  @Test func onlyOneActiveWallet() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    let wallet1 = WalletProfile(
      name: "Wallet 1", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "wsh(...)", internalDescriptor: "wsh(...)",
      network: .testnet4, isActive: true
    )
    let wallet2 = WalletProfile(
      name: "Wallet 2", requiredSignatures: 2, totalCosigners: 2,
      externalDescriptor: "wsh(...)", internalDescriptor: "wsh(...)",
      network: .testnet4, isActive: false
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

  @Test func cascadeDeleteCosigners() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    let wallet = WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 2,
      externalDescriptor: "wsh(...)", internalDescriptor: "wsh(...)",
      network: .testnet4, isActive: true
    )
    context.insert(wallet)

    let cosigner1 = CosignerInfo(
      label: "Cosigner 1", xpub: "tpubA", fingerprint: "aaaaaaaa",
      derivationPath: "m/48'/1'/0'/2'", orderIndex: 0
    )
    cosigner1.wallet = wallet
    context.insert(cosigner1)

    let cosigner2 = CosignerInfo(
      label: "Cosigner 2", xpub: "tpubB", fingerprint: "bbbbbbbb",
      derivationPath: "m/48'/1'/0'/2'", orderIndex: 1
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

  @Test func multisigDescription() {
    let wallet = WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "", internalDescriptor: "",
      network: .testnet4
    )
    #expect(wallet.multisigDescription == "2-of-3")
  }

  private func profile(electrumPort: Int = 0, addressGapLimit: Int = 20) -> WalletProfile {
    WalletProfile(
      name: "Test", requiredSignatures: 2, totalCosigners: 3,
      externalDescriptor: "", internalDescriptor: "",
      network: .testnet4, addressGapLimit: addressGapLimit, electrumPort: electrumPort
    )
  }

  /// A stored port that is not a port number must not trap: the wallet is loaded
  /// on every launch, so a trap there would make the app impossible to open.
  @Test(arguments: [65536, 500_022, -1, Int.max, Int.min])
  func outOfRangePortFallsBackToTheDefault(port: Int) {
    #expect(profile(electrumPort: port).electrumConfig.port == BitcoinNetwork.testnet4.defaultElectrumPort)
  }

  @Test func customPortIsUsedWhenItIsAPortNumber() {
    #expect(profile(electrumPort: 1).electrumConfig.port == 1)
    #expect(profile(electrumPort: 12345).electrumConfig.port == 12345)
    #expect(profile(electrumPort: 65535).electrumConfig.port == 65535)
    #expect(profile(electrumPort: 0).electrumConfig.port == BitcoinNetwork.testnet4.defaultElectrumPort)
  }

  /// The gap limit is converted to an unsigned count for every full scan and
  /// bounds the address list, so a stored value out of range must be held in.
  @Test func scanGapLimitStaysWithinRange() {
    #expect(profile(addressGapLimit: 20).scanGapLimit == 20)
    #expect(profile(addressGapLimit: InputLimits.maxGapLimit).scanGapLimit == InputLimits.maxGapLimit)

    #expect(profile(addressGapLimit: 0).scanGapLimit == 1)
    #expect(profile(addressGapLimit: -1).scanGapLimit == 1)
    #expect(profile(addressGapLimit: Int.min).scanGapLimit == 1)
    #expect(profile(addressGapLimit: InputLimits.maxGapLimit + 1).scanGapLimit == InputLimits.maxGapLimit)
    #expect(profile(addressGapLimit: Int.max).scanGapLimit == InputLimits.maxGapLimit)
  }

  @Test func multipleWalletsSwitching() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)

    for i in 1 ... 3 {
      let wallet = WalletProfile(
        name: "Wallet \(i)", requiredSignatures: 2, totalCosigners: 3,
        externalDescriptor: "wsh(...\(i))", internalDescriptor: "wsh(...\(i))",
        network: .testnet4, isActive: i == 1
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

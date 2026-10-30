@testable import birch
import Foundation
import SwiftData
import Testing

/// Wallets saved before Electrum servers were shared carry their own server fields
/// over to a server at launch
@MainActor
struct ElectrumServerMigrationTests {
  private func makeContext() throws -> ModelContext {
    let schema = Schema([WalletProfile.self, CosignerInfo.self, ElectrumServer.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    return ModelContext(container)
  }

  /// A wallet as one saved before servers were shared, with its own server fields
  @discardableResult
  private func legacyWallet(
    in context: ModelContext,
    network: BitcoinNetwork,
    host: String = "",
    port: Int = 0,
    ssl: Int = 0,
    insecure: Bool = false,
  ) -> WalletProfile {
    let wallet = WalletProfile(
      name: "Legacy \(host)", requiredSignatures: 1, totalCosigners: 1,
      externalDescriptor: "", internalDescriptor: "", network: network,
    )
    wallet.electrumServerMigrated = false
    wallet.electrumHost = host
    wallet.electrumPort = port
    wallet.electrumSSL = ssl
    wallet.electrumAllowInsecureSSL = insecure
    context.insert(wallet)
    return wallet
  }

  private func migrate(_ context: ModelContext) {
    var rng = SeededGenerator(seed: 7)
    ElectrumServerMigration.run(in: context, using: &rng)
  }

  @Test func `a wallet on the network default moves to the public server`() throws {
    let context = try makeContext()
    let testnet4 = legacyWallet(in: context, network: .testnet4)
    let signet = legacyWallet(in: context, network: .signet)
    migrate(context)

    #expect(testnet4.builtInElectrumServerID == "testnet4.mempool")
    #expect(signet.builtInElectrumServerID == "signet.mempool")
    #expect(testnet4.electrumServerMigrated)
    #expect(try context.fetch(FetchDescriptor<ElectrumServer>()).isEmpty)
  }

  @Test func `a typed-in public server's address moves to that public server`() throws {
    let context = try makeContext()
    let wallet = legacyWallet(in: context, network: .mainnet, host: "electrum.emzy.de", port: 50002, ssl: 2)
    migrate(context)
    #expect(wallet.builtInElectrumServerID == "mainnet.emzy")
    #expect(wallet.electrumServer == nil)
  }

  /// Two wallets that typed in the same server share one
  @Test func `custom hosts become one of the user's own servers`() throws {
    let context = try makeContext()
    let first = legacyWallet(in: context, network: .mainnet, host: "node.local", port: 50002)
    let second = legacyWallet(in: context, network: .mainnet, host: " node.local ", port: 50002)
    let tcp = legacyWallet(in: context, network: .mainnet, host: "node.local", port: 50001, ssl: 1)
    let testnet = legacyWallet(in: context, network: .testnet4, host: "node.local", port: 50002)
    migrate(context)

    let servers = try context.fetch(FetchDescriptor<ElectrumServer>())
    #expect(servers.count == 3)
    let shared = try #require(first.electrumServer)
    #expect(second.electrumServer?.id == shared.id)
    #expect(shared.host == "node.local")
    #expect(shared.useSSL)
    #expect(shared.bitcoinNetwork == .mainnet)
    // The host is matched without regard to case
    #expect(shared.matches(host: "NODE.LOCAL", port: 50002, useSSL: true))
    #expect(shared.displayName == "node.local")
    #expect(shared.trust == .system)
    #expect(tcp.electrumServer?.useSSL == false)
    #expect(tcp.electrumServer?.id != shared.id)
    #expect(testnet.electrumServer?.bitcoinNetwork == .testnet4)
  }

  /// "Allow insecure SSL" pinned nothing; the next connection pins what it sees
  @Test func `insecure SSL becomes trust on first use`() throws {
    let context = try makeContext()
    let wallet = legacyWallet(in: context, network: .mainnet, host: "umbrel.local", port: 50002, ssl: 2, insecure: true)
    migrate(context)
    let server = try #require(wallet.electrumServer)
    #expect(server.trustOnFirstUse)
    #expect(server.trust == .trustOnFirstUse)
    #expect(ElectrumServerPickerView.tags(for: .custom(server)) == ["Pins on next sync"])
  }

  @Test func `a port that isn't a port number takes the network's`() throws {
    let context = try makeContext()
    let wallet = legacyWallet(in: context, network: .testnet3, host: "node.local", port: 70000)
    migrate(context)
    #expect(wallet.electrumServer?.port == 60002)
  }

  @Test func `running it again changes nothing`() throws {
    let context = try makeContext()
    let wallet = legacyWallet(in: context, network: .mainnet, host: "node.local", port: 50002)
    migrate(context)
    let server = try #require(wallet.electrumServer)
    migrate(context)
    #expect(wallet.electrumServer?.id == server.id)
    #expect(try context.fetch(FetchDescriptor<ElectrumServer>()).count == 1)
  }

  /// A wallet whose server the user deleted keeps none
  @Test func `a wallet with no server keeps none`() throws {
    let context = try makeContext()
    let wallet = WalletProfile(name: "None", requiredSignatures: 1, totalCosigners: 1, externalDescriptor: "", internalDescriptor: "")
    context.insert(wallet)
    migrate(context)
    #expect(wallet.electrumServerChoice == nil)
  }

  /// A public server a later release drops gives way to another on the network
  @Test func `a dropped public server is replaced`() throws {
    let context = try makeContext()
    let wallet = WalletProfile(name: "Old", requiredSignatures: 1, totalCosigners: 1, externalDescriptor: "", internalDescriptor: "", network: .mainnet)
    context.insert(wallet)
    wallet.builtInElectrumServerID = "mainnet.retired"
    migrate(context)
    let choice = try #require(wallet.electrumServerChoice)
    #expect(choice.isPublic)
    #expect(choice.network == .mainnet)
  }
}

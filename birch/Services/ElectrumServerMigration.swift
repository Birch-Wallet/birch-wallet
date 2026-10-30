import Foundation
import SwiftData

private let logger = AppLog(.wallet)

/// Carries each wallet's own server fields, from before servers were shared between
/// wallets, over to a server: the public one when the wallet used the network's
/// default or typed in a public server's address, and otherwise one of the user's
/// own servers, shared by the wallets that typed in the same one. Runs at launch,
/// and does nothing for a wallet already carried over.
@MainActor
enum ElectrumServerMigration {
  static func run(in context: ModelContext) {
    var rng = SystemRandomNumberGenerator()
    run(in: context, using: &rng)
  }

  static func run(in context: ModelContext, using rng: inout some RandomNumberGenerator) {
    do {
      let wallets = try context.fetch(FetchDescriptor<WalletProfile>())
      var servers = try context.fetch(FetchDescriptor<ElectrumServer>())
      var changed = false
      for wallet in wallets where !wallet.electrumServerMigrated {
        migrate(wallet, servers: &servers, context: context, using: &rng)
        changed = true
      }
      // A public server a later release dropped: the wallet was trusting a public
      // server already, so another one on its network takes its place
      for wallet in wallets
        where wallet.electrumServer == nil && !wallet.builtInElectrumServerID.isEmpty && wallet.electrumServerChoice == nil
      {
        let replacement = ElectrumServerCatalog.servers(for: wallet.bitcoinNetwork).randomElement(using: &rng)
        logger.info(
          "Wallet '\(wallet.name)': public server \(wallet.builtInElectrumServerID) is gone, moving to \(replacement?.id ?? "none")",
        )
        wallet.setElectrumServer(replacement.map { .builtIn($0) })
        changed = true
      }
      if changed {
        try context.save()
      }
    } catch {
      logger.error("Electrum server migration failed: \(error.localizedDescription)")
    }
  }

  private static func migrate(
    _ wallet: WalletProfile,
    servers: inout [ElectrumServer],
    context: ModelContext,
    using rng: inout some RandomNumberGenerator,
  ) {
    let network = wallet.bitcoinNetwork
    let host = wallet.electrumHost.trimmingCharacters(in: .whitespaces)
    let port = (1 ... InputLimits.maxPort).contains(wallet.electrumPort) ? wallet.electrumPort : Int(network.defaultElectrumPort)
    // 0 was the network default, which was SSL on every network
    let useSSL = wallet.electrumSSL != 1
    defer { wallet.electrumServerMigrated = true }

    if host.isEmpty {
      // Every test network had a default server. Mainnet had none, so a mainnet
      // wallet can't have saved without a host; if one did, it gets a public one.
      let builtIn = ElectrumServerCatalog.servers(for: network).randomElement(using: &rng)
      wallet.setElectrumServer(builtIn.map { .builtIn($0) })
      logger.info("Wallet '\(wallet.name)': network default -> public server \(builtIn?.id ?? "none")")
      return
    }
    if useSSL, let builtIn = ElectrumServerCatalog.server(host: host, port: port, network: network) {
      wallet.setElectrumServer(.builtIn(builtIn))
      logger.info("Wallet '\(wallet.name)': \(host):\(port) -> public server \(builtIn.id)")
      return
    }

    let insecure = useSSL && wallet.electrumAllowInsecureSSL
    let server: ElectrumServer
    if let existing = servers.first(where: { $0.bitcoinNetwork == network && $0.matches(host: host, port: port, useSSL: useSSL) }) {
      server = existing
      // Another wallet on the same server accepted any certificate. Pinning the one
      // seen next also keeps this wallet connecting to a server iOS doesn't trust,
      // and one iOS does trust is left to system trust then.
      if insecure, server.certificateSHA256 == nil {
        server.trustOnFirstUse = true
      }
    } else {
      server = ElectrumServer(name: "", host: host, port: port, useSSL: useSSL, network: network, trustOnFirstUse: insecure)
      context.insert(server)
      servers.append(server)
    }
    wallet.setElectrumServer(.custom(server))
    logger.info(
      "Wallet '\(wallet.name)': \(useSSL ? "ssl" : "tcp")://\(host):\(port)\(insecure ? " (insecure SSL, pinned on next connection)" : "") "
        + "-> own server \(server.id)",
    )
  }
}

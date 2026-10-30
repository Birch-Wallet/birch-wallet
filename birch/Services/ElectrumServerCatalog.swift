import Foundation

/// A public Electrum server Birch ships. Read-only: a release changes the list, the
/// user doesn't. Wallets refer to one by its `id`, which never changes.
struct BuiltInElectrumServer: Identifiable, Hashable {
  let id: String
  let name: String
  let host: String
  let port: UInt16
  let network: BitcoinNetwork
  /// SHA-256 of the server's self-signed certificate. Nil when an authority iOS
  /// trusts signed it.
  var certificateSHA256: String?
  /// A signet server's block 1 hash (KnownSignet)
  var signetBlock1Hash: String?

  var config: ElectrumConfig {
    ElectrumConfig(host: host, port: port, useSSL: true, trust: certificateSHA256.map { .pinned($0) } ?? .system)
  }
}

/// The signets Birch can name. Every signet shares one genesis block, so block 0
/// can't tell them apart; block 1 can.
enum KnownSignet: CaseIterable {
  case signet
  case mutinynet

  var name: String {
    switch self {
    case .signet: "Signet"
    case .mutinynet: "Mutinynet"
    }
  }

  var block1Hash: String {
    switch self {
    case .signet: "00000086d6b2636cb2a392d45edc4ec544a10024d30141c9adf4bfd9de533b53"
    case .mutinynet: "000002855893a0a9b24eaffc5efc770558a326fee4fc10c9da22fc19cd2954f9"
    }
  }

  /// The signet's name, "Custom signet" for one Birch doesn't know, or nil while
  /// its block 1 is unknown
  static func name(forBlock1Hash hash: String?) -> String? {
    guard let hash else { return nil }
    return allCases.first { $0.block1Hash == hash.lowercased() }?.name ?? "Custom signet"
  }
}

/// A server a wallet can sync from: one Birch ships, or one the user added
enum ElectrumServerChoice: Identifiable, Equatable {
  case builtIn(BuiltInElectrumServer)
  case custom(ElectrumServer)

  var id: String {
    switch self {
    case let .builtIn(server): "builtin:\(server.id)"
    case let .custom(server): "custom:\(server.id.uuidString)"
    }
  }

  var displayName: String {
    switch self {
    case let .builtIn(server): server.name
    case let .custom(server): server.displayName
    }
  }

  var network: BitcoinNetwork {
    switch self {
    case let .builtIn(server): server.network
    case let .custom(server): server.bitcoinNetwork
    }
  }

  var config: ElectrumConfig {
    switch self {
    case let .builtIn(server): server.config
    case let .custom(server): server.config
    }
  }

  var hostPort: String {
    "\(config.host):\(config.port)"
  }

  /// The line under the name: the address, or only the port when the name is the
  /// host already (one of the user's servers left unnamed)
  var detail: String {
    displayName == config.host ? "Port \(config.port)" : hostPort
  }

  var isPublic: Bool {
    if case .builtIn = self {
      return true
    }
    return false
  }

  /// A public mainnet server: the wallet trusts someone else's node
  var showsOwnNodeWarning: Bool {
    isPublic && network == .mainnet
  }

  var isPinned: Bool {
    if case .pinned = config.trust {
      return true
    }
    return false
  }

  var signetBlock1Hash: String? {
    switch self {
    case let .builtIn(server): server.signetBlock1Hash
    case let .custom(server): server.signetBlock1Hash
    }
  }

  /// The signet's name, for a signet server whose block 1 is known
  var signetName: String? {
    network == .signet ? KnownSignet.name(forBlock1Hash: signetBlock1Hash) : nil
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
  }
}

enum ElectrumServerCatalog {
  /// Every public server, in the order the picker lists them
  static let servers: [BuiltInElectrumServer] = [
    BuiltInElectrumServer(
      id: "mainnet.sethforprivacy", name: "Seth For Privacy", host: "fulcrum.sethforprivacy.com", port: 50002,
      network: .mainnet, certificateSHA256: "4573c11f76136015f4cdab6aeafcc23d1621e2db0244e1a0607f6ea6fa101e91",
    ),
    BuiltInElectrumServer(id: "mainnet.diynodes", name: "DIYnodes", host: "electrum.diynodes.com", port: 50022, network: .mainnet),
    BuiltInElectrumServer(
      id: "mainnet.emzy", name: "Emzy", host: "electrum.emzy.de", port: 50002,
      network: .mainnet, certificateSHA256: "ae52a2307cb9878024b61dbf948d3aac8fea705dfefe562cc62191b6995c48cc",
    ),
    BuiltInElectrumServer(id: "testnet4.mempool", name: "mempool.space", host: "testnet4.mempool.space", port: 40002, network: .testnet4),
    BuiltInElectrumServer(id: "testnet3.blockstream", name: "Blockstream", host: "electrum.blockstream.info", port: 60002, network: .testnet3),
    BuiltInElectrumServer(
      id: "signet.mempool", name: "mempool.space", host: "signet.mempool.space", port: 60602,
      network: .signet, signetBlock1Hash: KnownSignet.signet.block1Hash,
    ),
  ]

  static func servers(for network: BitcoinNetwork) -> [BuiltInElectrumServer] {
    servers.filter { $0.network == network }
  }

  static func server(id: String) -> BuiltInElectrumServer? {
    servers.first { $0.id == id }
  }

  /// The public server at `host` and `port` on `network`, for a wallet saved with
  /// its address typed in
  static func server(host: String, port: Int, network: BitcoinNetwork) -> BuiltInElectrumServer? {
    servers.first {
      $0.network == network && $0.host.caseInsensitiveCompare(host) == .orderedSame && Int($0.port) == port
    }
  }

  /// The server a new wallet on `network` starts on: the user's own server for that
  /// network chosen most recently (or added most recently, when none has been
  /// chosen), and otherwise one of the public servers, at random. Nil only for a
  /// network with neither.
  static func defaultChoice(
    for network: BitcoinNetwork,
    customServers: [ElectrumServer],
    using rng: inout some RandomNumberGenerator,
  ) -> ElectrumServerChoice? {
    let own = customServers.filter { $0.bitcoinNetwork == network }
    if let lastUsed = own.max(by: { ($0.lastUsedAt ?? $0.createdAt) < ($1.lastUsedAt ?? $1.createdAt) }) {
      return .custom(lastUsed)
    }
    let publicServers = servers(for: network)
    #if DEBUG
      // The screenshot tour shows the same server every run
      if ScreenshotFixtures.isActive {
        return publicServers.first.map { .builtIn($0) }
      }
    #endif
    return publicServers.randomElement(using: &rng).map { .builtIn($0) }
  }

  static func defaultChoice(for network: BitcoinNetwork, customServers: [ElectrumServer]) -> ElectrumServerChoice? {
    var rng = SystemRandomNumberGenerator()
    return defaultChoice(for: network, customServers: customServers, using: &rng)
  }
}

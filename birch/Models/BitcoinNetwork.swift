import Foundation

enum BitcoinNetwork: String, CaseIterable, Codable, Identifiable {
  case mainnet = "bitcoin"
  case testnet4
  case testnet3 = "testnet"
  case signet

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .mainnet: "Mainnet"
    case .testnet4: "Testnet4"
    case .testnet3: "Testnet3"
    case .signet: "Signet"
    }
  }

  var coinType: Int {
    switch self {
    case .mainnet: 0
    case .testnet4, .testnet3, .signet: 1
    }
  }

  /// The usual SSL port of the network's Electrum servers, the Add Server sheet's
  /// placeholder. The public servers are in ElectrumServerCatalog.
  var defaultElectrumPort: UInt16 {
    switch self {
    case .mainnet: 50002
    case .testnet4: 40002
    case .testnet3: 60002
    case .signet: 60602
    }
  }

  /// The nonce of the network's genesis block, which tells a server's network from
  /// its block 0. Every signet shares one genesis block, so this says signet but
  /// not which (KnownSignet tells them apart by block 1).
  var genesisNonce: UInt32 {
    switch self {
    case .mainnet: 2_083_236_893
    case .testnet4: 393_743_547
    case .testnet3: 414_098_458
    case .signet: 52_613_770
    }
  }

  /// The network whose genesis block has `nonce`, or nil for one Birch doesn't support (regtest)
  init?(genesisNonce nonce: UInt32) {
    guard let network = Self.allCases.first(where: { $0.genesisNonce == nonce }) else { return nil }
    self = network
  }

  var addressPrefix: String {
    switch self {
    case .mainnet: "bc1"
    case .testnet4, .testnet3, .signet: "tb1"
    }
  }

  var xpubPrefix: String {
    switch self {
    case .mainnet: "xpub"
    case .testnet4, .testnet3, .signet: "tpub"
    }
  }

  /// BIP48 derivation path for P2WSH multisig
  var bip48DerivationPath: String {
    "m/48'/\(coinType)'/0'/2'"
  }

  /// Mempool.space base URL path for this network
  var mempoolPath: String {
    switch self {
    case .mainnet: ""
    case .testnet4: "/testnet4"
    case .testnet3: "/testnet"
    case .signet: "/signet"
    }
  }

  /// Block explorer base URL, using custom host or defaulting to mempool.space
  func explorerBaseURL(customHost: String? = nil) -> String {
    let host = (customHost?.isEmpty == false) ? customHost! : "mempool.space"
    return "https://\(host)\(mempoolPath)"
  }

  /// Full block explorer URL for a transaction
  func explorerTxURL(txid: String, customHost: String? = nil) -> URL? {
    URL(string: "\(explorerBaseURL(customHost: customHost))/tx/\(txid)")
  }

  /// Full block explorer URL for an address
  func explorerAddressURL(address: String, customHost: String? = nil) -> URL? {
    URL(string: "\(explorerBaseURL(customHost: customHost))/address/\(address)")
  }
}

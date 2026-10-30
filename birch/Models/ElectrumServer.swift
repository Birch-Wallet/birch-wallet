import Foundation
import SwiftData

/// An Electrum server the user added, for one network. Any wallet on that network
/// can use it. The public servers Birch ships are in ElectrumServerCatalog instead.
@Model
final class ElectrumServer {
  var id: UUID
  /// What the user called it. Empty shows the host.
  var name: String
  var host: String
  var port: Int
  var useSSL: Bool
  /// A BitcoinNetwork raw value
  var network: String
  /// SHA-256 of the certificate the user trusted, lowercase hex. Nil means an
  /// authority iOS trusts signed it, or the server is TCP.
  var certificateSHA256: String?
  /// Carried over from a wallet's "Allow insecure SSL": the next connection pins the
  /// certificate it sees (CertificateTrust.trustOnFirstUse)
  var trustOnFirstUse: Bool = false
  /// A signet's block 1 hash, which tells signets apart: they all share one genesis
  /// block. Nil on other networks, and on a signet server not yet connected to.
  var signetBlock1Hash: String?
  var createdAt: Date
  /// When a wallet last chose it. A new wallet starts on the one chosen last.
  var lastUsedAt: Date?

  @Relationship(deleteRule: .nullify, inverse: \WalletProfile.electrumServer)
  var wallets: [WalletProfile] = []

  init(
    id: UUID = UUID(),
    name: String,
    host: String,
    port: Int,
    useSSL: Bool,
    network: BitcoinNetwork,
    certificateSHA256: String? = nil,
    trustOnFirstUse: Bool = false,
    signetBlock1Hash: String? = nil,
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.useSSL = useSSL
    self.network = network.rawValue
    self.certificateSHA256 = certificateSHA256
    self.trustOnFirstUse = trustOnFirstUse
    self.signetBlock1Hash = signetBlock1Hash
    createdAt = .now
  }

  var bitcoinNetwork: BitcoinNetwork {
    BitcoinNetwork(rawValue: network) ?? .testnet4
  }

  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? host : trimmed
  }

  /// The stored port, or the network's usual one when the stored value is not a port
  /// number. It's read on every connection, so it must never trap.
  var validPort: UInt16 {
    (1 ... InputLimits.maxPort).contains(port) ? UInt16(port) : bitcoinNetwork.defaultElectrumPort
  }

  var trust: CertificateTrust {
    guard useSSL else { return .system }
    if let certificateSHA256 {
      return .pinned(certificateSHA256)
    }
    return trustOnFirstUse ? .trustOnFirstUse : .system
  }

  var config: ElectrumConfig {
    ElectrumConfig(host: host, port: validPort, useSSL: useSSL, trust: trust)
  }

  /// Whether `host`, `port` and the protocol name this server, as the Add sheet's
  /// duplicate check and the migration compare them
  func matches(host otherHost: String, port otherPort: Int, useSSL otherSSL: Bool) -> Bool {
    host.caseInsensitiveCompare(otherHost) == .orderedSame && port == otherPort && useSSL == otherSSL
  }
}

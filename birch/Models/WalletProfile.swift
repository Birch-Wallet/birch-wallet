import Foundation
import SwiftData

@Model
final class WalletProfile {
  var id: UUID
  var name: String
  var requiredSignatures: Int
  var totalCosigners: Int
  var externalDescriptor: String
  var internalDescriptor: String
  var network: String
  var createdAt: Date
  var isActive: Bool
  var addressGapLimit: Int
  var electrumHost: String
  var electrumPort: Int
  var electrumSSL: Int // 0 = network default, 1 = TCP, 2 = SSL
  var blockExplorerHost: String // empty = mempool.space
  var electrumAllowInsecureSSL: Bool = false
  var privacyMode: Bool = false

  @Relationship(deleteRule: .cascade, inverse: \CosignerInfo.wallet)
  var cosigners: [CosignerInfo]

  init(
    id: UUID = UUID(),
    name: String,
    requiredSignatures: Int,
    totalCosigners: Int,
    externalDescriptor: String,
    internalDescriptor: String,
    network: BitcoinNetwork = .testnet4,
    isActive: Bool = false,
    addressGapLimit: Int = 20,
    electrumHost: String = "",
    electrumPort: Int = 0,
    electrumSSL: Int = 0,
    electrumAllowInsecureSSL: Bool = false,
    blockExplorerHost: String = "",
    privacyMode: Bool = false
  ) {
    self.id = id
    self.name = name
    self.requiredSignatures = requiredSignatures
    self.totalCosigners = totalCosigners
    self.externalDescriptor = externalDescriptor
    self.internalDescriptor = internalDescriptor
    self.network = network.rawValue
    createdAt = Date()
    self.isActive = isActive
    self.addressGapLimit = addressGapLimit
    self.electrumHost = electrumHost
    self.electrumPort = electrumPort
    self.electrumSSL = electrumSSL
    self.electrumAllowInsecureSSL = electrumAllowInsecureSSL
    self.blockExplorerHost = blockExplorerHost
    self.privacyMode = privacyMode
    cosigners = []
  }

  var bitcoinNetwork: BitcoinNetwork {
    BitcoinNetwork(rawValue: network) ?? .testnet4
  }

  /// The custom server port, or nil when none is set. A stored value that is not
  /// a port number counts as not set: this is read on every wallet load, so it
  /// must never trap.
  var customElectrumPort: UInt16? {
    (1 ... InputLimits.maxPort).contains(electrumPort) ? UInt16(electrumPort) : nil
  }

  /// The gap limit to scan and list addresses with: the stored value held to
  /// 1...`InputLimits.maxGapLimit`, so one saved out of range cannot trap or
  /// scan without end.
  var scanGapLimit: Int {
    min(max(addressGapLimit, 1), InputLimits.maxGapLimit)
  }

  var electrumConfig: ElectrumConfig {
    let net = bitcoinNetwork
    let host = electrumHost.isEmpty ? (net.defaultElectrumHost ?? "") : electrumHost
    let port = customElectrumPort ?? net.defaultElectrumPort
    let ssl: Bool = switch electrumSSL {
    case 1: false // TCP
    case 2: true // SSL
    default: net.usesSSL // 0 = network default
    }
    return ElectrumConfig(host: host, port: port, useSSL: ssl, allowInsecureSSL: electrumAllowInsecureSSL)
  }

  var multisigDescription: String {
    "\(requiredSignatures)-of-\(totalCosigners)"
  }
}

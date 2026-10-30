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
  // The server the wallet had before Electrum servers were shared between wallets.
  // Only ElectrumServerMigration reads these; `electrumServer` and
  // `builtInElectrumServerID` replaced them.
  var electrumHost: String
  var electrumPort: Int
  var electrumSSL: Int // 0 = network default, 1 = TCP, 2 = SSL
  var blockExplorerHost: String // empty = mempool.space
  var electrumAllowInsecureSSL: Bool = false
  var privacyMode: Bool = false
  /// Where the wallet sits in the wallet picker, 0 first (see WalletOrdering)
  var sortOrder: Int = 0
  /// The user's own server the wallet syncs from. Nil when it uses a public one.
  var electrumServer: ElectrumServer?
  /// The public server the wallet syncs from (ElectrumServerCatalog), when
  /// `electrumServer` is nil. Empty too means the wallet has no server: the user
  /// deleted the one it used.
  var builtInElectrumServerID: String = ""
  /// The server fields above have been carried over to `electrumServer` or
  /// `builtInElectrumServerID`. False only for a wallet saved before servers were
  /// shared, until the migration runs.
  var electrumServerMigrated: Bool = false
  /// The signet the wallet's BDK database last synced from: its block 1 hash. Moving
  /// to a server on another signet clears the database first.
  var signetChainID: String?

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
    addressGapLimit: Int = Constants.defaultAddressGap,
    blockExplorerHost: String = "",
    privacyMode: Bool = false,
  ) {
    self.id = id
    self.name = name
    self.requiredSignatures = requiredSignatures
    self.totalCosigners = totalCosigners
    self.externalDescriptor = externalDescriptor
    self.internalDescriptor = internalDescriptor
    self.network = network.rawValue
    // Wallet Settings shows it, so the screenshot tour freezes it too
    createdAt = .displayNow
    self.isActive = isActive
    self.addressGapLimit = addressGapLimit
    electrumHost = ""
    electrumPort = 0
    electrumSSL = 0
    self.blockExplorerHost = blockExplorerHost
    self.privacyMode = privacyMode
    // A new wallet has no fields to carry over; it gets its server once it's
    // inserted (setElectrumServer)
    electrumServerMigrated = true
    cosigners = []
  }

  var bitcoinNetwork: BitcoinNetwork {
    BitcoinNetwork(rawValue: network) ?? .testnet4
  }

  /// The gap limit to scan and list addresses with: the stored value held to
  /// 1...`InputLimits.maxGapLimit`, so one saved out of range cannot trap or
  /// scan without end.
  var scanGapLimit: Int {
    min(max(addressGapLimit, 1), InputLimits.maxGapLimit)
  }

  /// The server the wallet syncs from, or nil when it has none
  var electrumServerChoice: ElectrumServerChoice? {
    if let electrumServer {
      return .custom(electrumServer)
    }
    return ElectrumServerCatalog.server(id: builtInElectrumServerID).map { .builtIn($0) }
  }

  /// Where the wallet connects, or nil when it has no server
  var electrumConfig: ElectrumConfig? {
    electrumServerChoice?.config
  }

  /// Moves the wallet to `choice`, or to no server
  func setElectrumServer(_ choice: ElectrumServerChoice?) {
    switch choice {
    case let .builtIn(server):
      electrumServer = nil
      builtInElectrumServerID = server.id
    case let .custom(server):
      electrumServer = server
      builtInElectrumServerID = ""
    case nil:
      electrumServer = nil
      builtInElectrumServerID = ""
    }
  }

  var multisigDescription: String {
    "\(requiredSignatures)-of-\(totalCosigners)"
  }
}

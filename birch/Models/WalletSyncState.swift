import Foundation

enum WalletSyncState: Equatable {
  case notStarted
  case syncing(String = "Refreshing…")
  case synced(Date)
  case error(String)

  var isSyncing: Bool {
    if case .syncing = self { return true }
    return false
  }

  var syncMessage: String? {
    if case let .syncing(msg) = self { return msg }
    return nil
  }

  var lastSynced: Date? {
    if case let .synced(date) = self { return date }
    return nil
  }

  var errorMessage: String? {
    if case let .error(msg) = self { return msg }
    return nil
  }
}

enum SyncType: CustomStringConvertible {
  case none
  case fullScan
  case incremental

  var description: String {
    switch self {
    case .none: "none"
    case .fullScan: "full scan"
    case .incremental: "incremental"
    }
  }
}

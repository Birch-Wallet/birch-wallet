import Foundation

enum WalletSyncState: Equatable {
  case notStarted
  case syncing(SyncPhase = .connecting)
  case synced(Date)
  case error(String)

  var isSyncing: Bool {
    if case .syncing = self {
      return true
    }
    return false
  }

  var syncPhase: SyncPhase? {
    if case let .syncing(phase) = self {
      return phase
    }
    return nil
  }

  var lastSynced: Date? {
    if case let .synced(date) = self {
      return date
    }
    return nil
  }

  var errorMessage: String? {
    if case let .error(msg) = self {
      return msg
    }
    return nil
  }
}

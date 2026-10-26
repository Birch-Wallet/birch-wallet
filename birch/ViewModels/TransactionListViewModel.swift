import Foundation
import Observation

@Observable
@MainActor
final class TransactionListViewModel {
  var transactions: [TransactionItem] = []
  var isLoading = false
  var balance: UInt64 = 0
  var walletName: String = ""
  var network: BitcoinNetwork = .testnet4
  var multisigDescription: String = ""
  private var expectedProfileId: UUID?

  private var bitcoinService: BitcoinService {
    BitcoinService.shared
  }

  var syncState: WalletSyncState {
    bitcoinService.syncState
  }

  var syncProgress: Double? {
    bitcoinService.syncProgress
  }

  func clearState() {
    transactions = []
    balance = 0
    isLoading = true
  }

  func loadActiveWallet(from wallets: [WalletProfile]) {
    guard let active = wallets.first(where: { $0.isActive }) else { return }
    expectedProfileId = active.id
    walletName = active.name
    network = active.bitcoinNetwork
    multisigDescription = active.multisigDescription

    let alreadyLoaded = bitcoinService.currentProfile?.id == active.id && bitcoinService.wallet != nil
    if alreadyLoaded {
      updateFromService()
    } else if !bitcoinService.syncState.isSyncing {
      // Cold start: BitcoinService has no wallet loaded yet
      isLoading = true
      Task {
        do {
          try await bitcoinService.loadWallet(profile: active)
          updateFromService()
          try await bitcoinService.syncOnOpen()
          updateFromService()
        } catch {
          // syncState is managed by BitcoinService
        }
        isLoading = false
      }
    }
  }

  func updateFromService() {
    guard bitcoinService.currentProfile?.id == expectedProfileId else { return }
    balance = bitcoinService.balance
    transactions = bitcoinService.transactions
  }

  /// Starts a sync without waiting for it, so pull-to-refresh lets go at once and
  /// the header's progress bar takes over
  func startSync() {
    isLoading = true
    Task {
      do {
        try await bitcoinService.sync()
        updateFromService()
      } catch {
        // syncState is managed by BitcoinService
      }
      isLoading = false
    }
  }
}

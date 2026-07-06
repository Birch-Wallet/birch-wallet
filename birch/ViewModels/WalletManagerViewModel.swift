import Foundation
import Observation
import SwiftData

private let logger = AppLog(.wallet)

@Observable
@MainActor
final class WalletManagerViewModel {
  var errorMessage: String?

  func setActiveWallet(_ wallet: WalletProfile, allWallets: [WalletProfile], modelContext: ModelContext) {
    logger.info("Switching active wallet to \(wallet.name)")
    for w in allWallets {
      w.isActive = (w.id == wallet.id)
    }

    do {
      try modelContext.save()
      // Only update UserDefaults after successful DB save
      UserDefaults.standard.set(wallet.id.uuidString, forKey: Constants.activeWalletIDKey)
      // Immediately clear stale wallet data so the UI never briefly shows old transactions/addresses
      BitcoinService.shared.unloadWallet()
      BitcoinService.shared.syncTask = Task {
        do {
          try await BitcoinService.shared.loadWallet(profile: wallet)
          try await BitcoinService.shared.sync()
        } catch {
          logger.error("Failed to load/sync wallet: \(error)")
        }
      }
    } catch {
      logger.error("Failed to save active wallet: \(error)")
      errorMessage = error.localizedDescription
    }
  }

  func deleteWallet(_ wallet: WalletProfile, modelContext: ModelContext) {
    logger.info("Deleting wallet \(wallet.name)")
    let wasActive = wallet.isActive
    let walletID = wallet.id

    // Delete associated records that use walletID (not covered by cascade)
    do {
      let frozenDescriptor = FetchDescriptor<FrozenUTXO>(predicate: #Predicate { $0.walletID == walletID })
      for frozen in try modelContext.fetch(frozenDescriptor) {
        modelContext.delete(frozen)
      }
      let labelDescriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate { $0.walletID == walletID })
      for label in try modelContext.fetch(labelDescriptor) {
        modelContext.delete(label)
      }
      let psbtDescriptor = FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.walletID == walletID })
      for psbt in try modelContext.fetch(psbtDescriptor) {
        modelContext.delete(psbt)
      }
    } catch {
      logger.error("Failed to fetch associated records for deletion: \(error)")
      errorMessage = error.localizedDescription
      return
    }

    modelContext.delete(wallet)

    // If the active wallet was deleted, activate another one before saving
    if wasActive {
      let remaining = (try? modelContext.fetch(FetchDescriptor<WalletProfile>())) ?? []
      if let next = remaining.first {
        next.isActive = true
      }
    }

    // Single atomic save for all deletes + reactivation
    do {
      try modelContext.save()

      // Update UserDefaults only after successful save
      if wasActive {
        let remaining = (try? modelContext.fetch(FetchDescriptor<WalletProfile>())) ?? []
        if let next = remaining.first(where: { $0.isActive }) {
          UserDefaults.standard.set(next.id.uuidString, forKey: Constants.activeWalletIDKey)
          BitcoinService.shared.unloadWallet()
          Task {
            try? await BitcoinService.shared.loadWallet(profile: next)
          }
        } else {
          UserDefaults.standard.removeObject(forKey: Constants.activeWalletIDKey)
        }
      }

      // Clean up wallet storage after successful DB save
      let walletDir = Constants.walletDirectory(for: walletID)
      try? FileManager.default.removeItem(at: walletDir)
    } catch {
      logger.error("Failed to save wallet deletion: \(error)")
      errorMessage = error.localizedDescription
    }
  }
}

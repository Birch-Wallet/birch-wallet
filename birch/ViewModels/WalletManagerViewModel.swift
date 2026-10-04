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
      // Run loadWallet in a plain task — it must NOT be stored in syncTask, because
      // loadWallet cancels syncTask to kill any in-flight sync. If this task were
      // stored there, loadWallet would cancel itself and the following sync would
      // immediately throw CancellationError. Only the sync itself belongs in syncTask.
      Task {
        do {
          try await BitcoinService.shared.loadWallet(profile: wallet)
          let syncTask = Task { try await BitcoinService.shared.sync() }
          BitcoinService.shared.syncTask = syncTask
          try await syncTask.value
        } catch {
          logger.error("Failed to load/sync wallet: \(error)")
        }
      }
    } catch {
      logger.error("Failed to save active wallet: \(error)")
      errorMessage = error.localizedDescription
    }
  }

  /// Replaces a wallet's cosigner details and rebuilds its descriptors from them.
  /// Returns false with `errorMessage` set, leaving the wallet as it was, when
  /// the edited cosigners cannot be saved.
  @discardableResult
  func updateCosigners(
    of wallet: WalletProfile,
    to edited: [(label: String, xpub: String, fingerprint: String, derivationPath: String)],
    modelContext: ModelContext
  ) -> Bool {
    let network = wallet.bitcoinNetwork
    let existingCosigners = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }

    // The wallet's M-of-N is fixed; only the details of each cosigner can change
    guard edited.count == existingCosigners.count else {
      errorMessage = "The number of cosigners cannot be changed"
      return false
    }

    // Validate all cosigners
    let isTestnet = network != .mainnet
    let existingXpubs = Set(existingCosigners.compactMap { URService.canonicalXpub($0.xpub, isTestnet: isTestnet) })
    var canonicalXpubs: [String?] = []
    for (i, cosigner) in edited.enumerated() {
      // Compare in standard form, so a Vpub and its tpub count as the same key
      let canonical = URService.canonicalXpub(cosigner.xpub, isTestnet: isTestnet)
      // A key that is being added must sit at the BIP48 path. One that is already
      // in the wallet is left alone: existing wallets are not re-checked.
      let isNewKey = canonical.map { !existingXpubs.contains($0) } ?? true
      if let error = SetupWizardViewModel.validateXpub(cosigner.xpub, for: network, checkingPlacement: isNewKey) {
        errorMessage = "Cosigner \(i + 1): \(error)"
        return false
      }
      if let duplicate = canonicalXpubs.firstIndex(of: canonical) {
        errorMessage = "Cosigner \(i + 1) has the same xpub as Cosigner \(duplicate + 1)"
        return false
      }
      canonicalXpubs.append(canonical)
      if cosigner.fingerprint.count != 8 || !cosigner.fingerprint.allSatisfy(\.isHexDigit) {
        errorMessage = "Cosigner \(i + 1) has an invalid fingerprint"
        return false
      }
      if let error = SetupWizardViewModel.validateDerivationPath(cosigner.derivationPath, for: network) {
        errorMessage = "Cosigner \(i + 1): \(error)"
        return false
      }
    }

    // Rebuild descriptors from the edited cosigner data before changing any
    // record, so a key that cannot go into a descriptor leaves the wallet as it was
    let cosignerData = edited.map {
      (xpub: $0.xpub, fingerprint: $0.fingerprint, derivationPath: $0.derivationPath)
    }
    let extDesc: String
    let intDesc: String
    do {
      extDesc = try BitcoinService.buildDescriptor(
        requiredSignatures: wallet.requiredSignatures,
        cosigners: cosignerData,
        network: network,
        isChange: false
      )
      intDesc = try BitcoinService.buildDescriptor(
        requiredSignatures: wallet.requiredSignatures,
        cosigners: cosignerData,
        network: network,
        isChange: true
      )
    } catch {
      errorMessage = error.localizedDescription
      return false
    }

    errorMessage = nil

    // Update cosigner records in SwiftData
    for (cosigner, edit) in zip(existingCosigners, edited) {
      cosigner.label = edit.label
      cosigner.xpub = edit.xpub.trimmingCharacters(in: .whitespacesAndNewlines)
      cosigner.fingerprint = edit.fingerprint
      cosigner.derivationPath = edit.derivationPath
    }

    wallet.externalDescriptor = extDesc
    wallet.internalDescriptor = intDesc

    logger.info("Cosigner changes saved, rebuilding descriptors")

    // Delete old BDK wallet database so it reloads fresh
    let dbPath = Constants.walletDatabasePath(for: wallet.id)
    try? FileManager.default.removeItem(at: dbPath)

    do {
      try modelContext.save()
    } catch {
      logger.error("Failed to save cosigner changes: \(error)")
    }

    // Reload wallet if this is the active wallet
    if wallet.isActive {
      Task {
        try? await BitcoinService.shared.loadWallet(profile: wallet)
        try? await BitcoinService.shared.fullResync()
      }
    }

    return true
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

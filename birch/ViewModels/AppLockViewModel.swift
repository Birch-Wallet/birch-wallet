import CryptoKit
import Foundation
import LocalAuthentication
import SwiftData

private let logger = AppLog(.security)

@Observable
@MainActor
final class AppLockViewModel {
  var isLocked = true
  var needsPINEntry = false
  var isAuthenticating = false
  var pinInput = ""
  var pinError = ""

  private(set) var failedAttempts: Int = 0
  private(set) var lockoutExpiry: Date?
  private var backgroundTime: Date?
  private let keychain: KeychainStoring.Type

  // MARK: - Computed

  var isLockedOut: Bool {
    guard let expiry = lockoutExpiry else { return false }
    return Date() < expiry
  }

  var lockoutRemainingText: String {
    guard let expiry = lockoutExpiry else { return "" }
    let remaining = expiry.timeIntervalSinceNow
    guard remaining > 0 else { return "" }
    if remaining > 3600 {
      let hours = Int(remaining / 3600)
      let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
      return "Try again in \(hours)h \(minutes)m"
    } else if remaining > 60 {
      return "Try again in \(Int(remaining / 60))m"
    } else {
      return "Try again in \(Int(remaining))s"
    }
  }

  private(set) var hasPIN: Bool = false

  private(set) var storedPINLength: Int = 6

  // MARK: - Init

  init(keychain: KeychainStoring.Type = KeychainHelper.self) {
    self.keychain = keychain
    hasPIN = keychain.load(forKey: Constants.keychainPINHashKey) != nil
    if let data = keychain.load(forKey: Constants.keychainPINLengthKey),
       let str = String(data: data, encoding: .utf8),
       let len = Int(str)
    {
      storedPINLength = len
    }
    loadPersistedState()
  }

  // MARK: - Authentication

  func authenticate() {
    guard !isAuthenticating else { return }
    isAuthenticating = true
    logger.info("Starting biometric authentication")

    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      logger.warning("Biometric policy unavailable: \(error?.localizedDescription ?? "unknown")")
      isLocked = false
      isAuthenticating = false
      return
    }

    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock \(Constants.appName)") { success, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if success {
          if hasPIN {
            logger.info("Biometric success, requesting PIN")
            needsPINEntry = true
          } else {
            logger.info("Biometric success, app unlocked")
            isLocked = false
          }
        } else {
          logger.info("Biometric authentication declined")
        }
        isAuthenticating = false
      }
    }
  }

  // MARK: - PIN Management

  func verifyPIN(_ pin: String) -> Bool {
    if isLockedOut {
      pinError = lockoutRemainingText
      pinInput = ""
      return false
    }

    guard let storedHash = keychain.load(forKey: Constants.keychainPINHashKey) else {
      return false
    }

    let inputHash = hashPIN(pin)
    if inputHash == storedHash {
      logger.info("PIN verified successfully, app unlocked")
      failedAttempts = 0
      persistFailedAttempts()
      lockoutExpiry = nil
      persistLockoutExpiry()
      pinError = ""
      needsPINEntry = false
      isLocked = false
      return true
    } else {
      failedAttempts += 1
      persistFailedAttempts()
      applyLockout()
      pinInput = ""
      let attempts = failedAttempts
      logger.warning("PIN verification failed (attempt \(attempts)/10)")
      if failedAttempts >= 10 {
        pinError = "Too many attempts"
      } else if isLockedOut {
        pinError = lockoutRemainingText
      } else {
        pinError = "Incorrect PIN (\(failedAttempts)/10)"
      }
      return false
    }
  }

  func setPIN(_ pin: String) {
    logger.info("PIN set (\(pin.count) digits)")
    let hash = hashPIN(pin)
    keychain.save(hash, forKey: Constants.keychainPINHashKey)
    keychain.save(Data("\(pin.count)".utf8), forKey: Constants.keychainPINLengthKey)
    failedAttempts = 0
    persistFailedAttempts()
    lockoutExpiry = nil
    persistLockoutExpiry()
    hasPIN = true
    storedPINLength = pin.count
  }

  func removePIN() {
    logger.info("PIN removed")
    keychain.delete(forKey: Constants.keychainPINHashKey)
    keychain.delete(forKey: Constants.keychainPINLengthKey)
    keychain.delete(forKey: Constants.keychainFailedAttemptsKey)
    keychain.delete(forKey: Constants.keychainLockoutExpiryKey)
    failedAttempts = 0
    lockoutExpiry = nil
    hasPIN = false
    storedPINLength = 6
  }

  // MARK: - Background / Foreground

  func handleBackground(at date: Date = Date()) {
    if backgroundTime == nil {
      logger.info("App entering background")
      backgroundTime = date
    }
  }

  func handleForeground(timeout: Int) {
    hasPIN = keychain.load(forKey: Constants.keychainPINHashKey) != nil
    if let data = keychain.load(forKey: Constants.keychainPINLengthKey),
       let str = String(data: data, encoding: .utf8),
       let len = Int(str)
    {
      storedPINLength = len
    } else {
      storedPINLength = 6
    }
    if let bgTime = backgroundTime {
      let elapsed = Int(Date().timeIntervalSince(bgTime))
      if elapsed >= timeout {
        logger.info("Inactivity timeout exceeded (\(elapsed)s >= \(timeout)s), re-locking")
        isLocked = true
        needsPINEntry = false
        pinInput = ""
        pinError = ""
        authenticate()
      } else {
        logger.info("App returning to foreground (\(elapsed)s < \(timeout)s timeout)")
      }
    }
    backgroundTime = nil
  }

  // MARK: - Data Wipe

  func wipeAllData(modelContext: ModelContext) {
    let attempts = failedAttempts
    logger.critical("Wiping all data after \(attempts) failed PIN attempts")
    // Delete SwiftData records
    try? modelContext.delete(model: WalletProfile.self)
    try? modelContext.delete(model: CosignerInfo.self)
    try? modelContext.delete(model: WalletLabel.self)
    try? modelContext.delete(model: FrozenUTXO.self)
    try? modelContext.delete(model: SavedPSBT.self)
    try? modelContext.save()

    // Delete wallet files
    try? FileManager.default.removeItem(at: Constants.walletsDirectory())

    // Clear UserDefaults
    if let bundleID = Bundle.main.bundleIdentifier {
      UserDefaults.standard.removePersistentDomain(forName: bundleID)
    }

    // Clear Keychain
    keychain.deleteAll()

    // Reset BitcoinService
    BitcoinService.shared.unloadWallet()

    // Unlock — wiped state will show setup wizard
    isLocked = false
    needsPINEntry = false
    failedAttempts = 0
    lockoutExpiry = nil
  }

  // MARK: - Private

  private func hashPIN(_ pin: String) -> Data {
    let digest = SHA256.hash(data: Data(pin.utf8))
    return Data(digest)
  }

  private func applyLockout() {
    let delay: TimeInterval? = switch failedAttempts {
    case 1 ... 3: nil
    case 4: 60
    case 5: 600
    case 6: 5400
    case 7 ... 9: 86400
    default: nil // 10+ handled by wipe
    }
    if let delay {
      let attempts = failedAttempts
      logger.warning("Lockout applied: \(Int(delay))s after \(attempts) failed attempts")
      lockoutExpiry = Date().addingTimeInterval(delay)
      persistLockoutExpiry()
    }
  }

  private func loadPersistedState() {
    if let data = keychain.load(forKey: Constants.keychainFailedAttemptsKey),
       let str = String(data: data, encoding: .utf8),
       let count = Int(str)
    {
      failedAttempts = count
    }
    if let data = keychain.load(forKey: Constants.keychainLockoutExpiryKey),
       let str = String(data: data, encoding: .utf8),
       let interval = Double(str)
    {
      let date = Date(timeIntervalSince1970: interval)
      lockoutExpiry = date > Date() ? date : nil
    }
  }

  private func persistFailedAttempts() {
    keychain.save(Data("\(failedAttempts)".utf8), forKey: Constants.keychainFailedAttemptsKey)
  }

  private func persistLockoutExpiry() {
    if let expiry = lockoutExpiry {
      keychain.save(Data("\(expiry.timeIntervalSince1970)".utf8), forKey: Constants.keychainLockoutExpiryKey)
    } else {
      keychain.delete(forKey: Constants.keychainLockoutExpiryKey)
    }
  }
}

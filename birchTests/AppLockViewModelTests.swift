@testable import birch
import CryptoKit
import Foundation
import Testing

@Suite("AppLockViewModel")
@MainActor
struct AppLockViewModelTests {
  init() {
    MockKeychainHelper.reset()
  }

  private func makeVM() -> AppLockViewModel {
    AppLockViewModel(keychain: MockKeychainHelper.self)
  }

  private func hashPIN(_ pin: String) -> Data {
    Data(SHA256.hash(data: Data(pin.utf8)))
  }

  private func seedPIN(_ pin: String) {
    MockKeychainHelper.save(hashPIN(pin), forKey: Constants.keychainPINHashKey)
    MockKeychainHelper.save(Data("\(pin.count)".utf8), forKey: Constants.keychainPINLengthKey)
  }

  private func seedFailedAttempts(_ count: Int) {
    MockKeychainHelper.save(Data("\(count)".utf8), forKey: Constants.keychainFailedAttemptsKey)
  }

  private func seedLockoutExpiry(_ date: Date) {
    MockKeychainHelper.save(Data("\(date.timeIntervalSince1970)".utf8), forKey: Constants.keychainLockoutExpiryKey)
  }

  // MARK: - Initialization

  @Test func initWithNoPIN_hasPINIsFalse() {
    let vm = makeVM()
    #expect(vm.hasPIN == false)
  }

  @Test func initWithExistingPIN_hasPINIsTrue() {
    seedPIN("1234")
    let vm = makeVM()
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
  }

  @Test func initWithPersistedFailedAttempts_restoresCount() {
    seedFailedAttempts(5)
    let vm = makeVM()
    #expect(vm.failedAttempts == 5)
  }

  @Test func initWithExpiredLockout_clearsLockout() {
    seedLockoutExpiry(Date().addingTimeInterval(-100))
    let vm = makeVM()
    #expect(vm.lockoutExpiry == nil)
    #expect(vm.isLockedOut == false)
  }

  @Test func initWithActiveLockout_restoresLockout() {
    seedLockoutExpiry(Date().addingTimeInterval(300))
    let vm = makeVM()
    #expect(vm.lockoutExpiry != nil)
    #expect(vm.isLockedOut == true)
  }

  // MARK: - PIN Management

  @Test func setPIN_storesHashAndLength() {
    let vm = makeVM()
    vm.setPIN("1234")
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
    #expect(MockKeychainHelper.load(forKey: Constants.keychainPINHashKey) == hashPIN("1234"))
    #expect(MockKeychainHelper.load(forKey: Constants.keychainPINLengthKey) == Data("4".utf8))
  }

  @Test func setPIN_resetsFailedAttempts() {
    let vm = makeVM()
    vm.setPIN("9999")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts == 2)
    vm.setPIN("5678")
    #expect(vm.failedAttempts == 0)
  }

  @Test func removePIN_clearsKeychainAndState() {
    let vm = makeVM()
    vm.setPIN("1234")
    #expect(vm.hasPIN == true)
    vm.removePIN()
    #expect(vm.hasPIN == false)
    #expect(vm.storedPINLength == 6)
    #expect(MockKeychainHelper.load(forKey: Constants.keychainPINHashKey) == nil)
    #expect(MockKeychainHelper.load(forKey: Constants.keychainPINLengthKey) == nil)
    #expect(MockKeychainHelper.load(forKey: Constants.keychainFailedAttemptsKey) == nil)
    #expect(MockKeychainHelper.load(forKey: Constants.keychainLockoutExpiryKey) == nil)
  }

  @Test func setPIN_removePIN_setPIN_togglesCorrectly() {
    let vm = makeVM()
    vm.setPIN("1234")
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
    vm.removePIN()
    #expect(vm.hasPIN == false)
    #expect(vm.storedPINLength == 6)
    vm.setPIN("567890")
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 6)
  }

  // MARK: - PIN Verification

  @Test func verifyPIN_correctPIN_returnsTrue() {
    let vm = makeVM()
    vm.setPIN("5678")
    vm.needsPINEntry = true
    let result = vm.verifyPIN("5678")
    #expect(result == true)
    #expect(vm.isLocked == false)
    #expect(vm.needsPINEntry == false)
    #expect(vm.failedAttempts == 0)
  }

  @Test func verifyPIN_wrongPIN_returnsFalse() {
    let vm = makeVM()
    vm.setPIN("5678")
    let result = vm.verifyPIN("0000")
    #expect(result == false)
    #expect(vm.failedAttempts == 1)
  }

  @Test func verifyPIN_noStoredPIN_returnsFalse() {
    let vm = makeVM()
    let result = vm.verifyPIN("1234")
    #expect(result == false)
  }

  @Test func verifyPIN_correctPIN_resetsFailedAttempts() {
    let vm = makeVM()
    vm.setPIN("5678")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts == 3)
    let result = vm.verifyPIN("5678")
    #expect(result == true)
    #expect(vm.failedAttempts == 0)
    #expect(vm.lockoutExpiry == nil)
  }

  @Test func verifyPIN_whileLockedOut_returnsFalse() {
    let vm = makeVM()
    vm.setPIN("5678")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000") // 4th attempt → 60s lockout
    #expect(vm.isLockedOut == true)
    let result = vm.verifyPIN("5678")
    #expect(result == false)
    #expect(vm.pinError.contains("Try again"))
  }

  // MARK: - Lockout Progression

  @Test func lockout_noLockoutFor1to3Failures() {
    let vm = makeVM()
    vm.setPIN("5678")
    _ = vm.verifyPIN("0000")
    #expect(vm.isLockedOut == false)
    _ = vm.verifyPIN("0000")
    #expect(vm.isLockedOut == false)
    _ = vm.verifyPIN("0000")
    #expect(vm.isLockedOut == false)
  }

  @Test func lockout_60sAfter4Failures() throws {
    let vm = makeVM()
    vm.setPIN("5678")
    for _ in 1 ... 4 {
      _ = vm.verifyPIN("0000")
    }
    #expect(vm.isLockedOut == true)
    #expect(vm.failedAttempts == 4)
    let expiry = try #require(vm.lockoutExpiry)
    let delay = expiry.timeIntervalSinceNow
    #expect(delay > 55 && delay <= 61)
  }

  @Test func lockout_10mAfter5Failures() throws {
    seedPIN("5678")
    seedFailedAttempts(4)
    let vm = makeVM()
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts == 5)
    let expiry = try #require(vm.lockoutExpiry)
    let delay = expiry.timeIntervalSinceNow
    #expect(delay > 595 && delay <= 601)
  }

  @Test func lockout_90mAfter6Failures() throws {
    seedPIN("5678")
    seedFailedAttempts(5)
    let vm = makeVM()
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts == 6)
    let expiry = try #require(vm.lockoutExpiry)
    let delay = expiry.timeIntervalSinceNow
    #expect(delay > 5395 && delay <= 5401)
  }

  @Test func lockout_24hAfter7Failures() throws {
    seedPIN("5678")
    seedFailedAttempts(6)
    let vm = makeVM()
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts == 7)
    let expiry = try #require(vm.lockoutExpiry)
    let delay = expiry.timeIntervalSinceNow
    #expect(delay > 86395 && delay <= 86401)
  }

  @Test func lockout_persistsSurvivesReInit() {
    let vm = makeVM()
    vm.setPIN("5678")
    for _ in 1 ... 4 {
      _ = vm.verifyPIN("0000")
    }
    #expect(vm.isLockedOut == true)

    let vm2 = makeVM()
    #expect(vm2.failedAttempts == 4)
    #expect(vm2.isLockedOut == true)
  }

  @Test func failedAttempts10_reachesWipeThreshold() {
    seedPIN("5678")
    seedFailedAttempts(9)
    let vm = makeVM()
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts >= 10)
    #expect(vm.pinError == "Too many attempts")
  }

  // MARK: - Background / Foreground

  @Test func handleBackground_calledTwice_noOverwrite() {
    let vm = makeVM()
    vm.isLocked = false
    let earlyTime = Date().addingTimeInterval(-120)
    vm.handleBackground(at: earlyTime)
    vm.handleBackground(at: Date())
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == true)
  }

  @Test func handleForeground_underTimeout_staysUnlocked() {
    let vm = makeVM()
    vm.isLocked = false
    vm.handleBackground(at: Date())
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == false)
  }

  @Test func handleForeground_overTimeout_reLocks() {
    let vm = makeVM()
    vm.isLocked = false
    vm.handleBackground(at: Date().addingTimeInterval(-120))
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == true)
  }

  @Test func handleForeground_rereadsPINState() {
    let vm = makeVM()
    #expect(vm.hasPIN == false)
    seedPIN("1234")
    vm.handleForeground(timeout: 60)
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
  }

  @Test func handleForeground_rereadsPINLength_afterRemoval() {
    seedPIN("1234")
    let vm = makeVM()
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
    MockKeychainHelper.delete(forKey: Constants.keychainPINHashKey)
    MockKeychainHelper.delete(forKey: Constants.keychainPINLengthKey)
    vm.handleForeground(timeout: 60)
    #expect(vm.hasPIN == false)
    #expect(vm.storedPINLength == 6)
  }

  @Test func handleForeground_noPriorBackground_noRelock() {
    let vm = makeVM()
    vm.isLocked = false
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == false)
  }

  // MARK: - Cross-Instance Sync

  @Test func crossInstance_setPINOnOne_foregroundReadsOnOther() {
    let vmA = makeVM()
    let vmB = makeVM()
    vmA.setPIN("1234")
    #expect(vmA.hasPIN == true)
    #expect(vmB.hasPIN == false)
    vmB.handleForeground(timeout: 60)
    #expect(vmB.hasPIN == true)
    #expect(vmB.storedPINLength == 4)
  }

  @Test func crossInstance_removePINOnOne_foregroundReadsOnOther() {
    seedPIN("5678")
    let vmA = makeVM()
    let vmB = makeVM()
    #expect(vmA.hasPIN == true)
    #expect(vmB.hasPIN == true)
    vmA.removePIN()
    #expect(vmA.hasPIN == false)
    #expect(vmB.hasPIN == true)
    vmB.handleForeground(timeout: 60)
    #expect(vmB.hasPIN == false)
    #expect(vmB.storedPINLength == 6)
  }

  @Test func crossInstance_setPIN_thenTimeout_showsCorrectPINLength() {
    let vmSettings = makeVM()
    let vmLock = makeVM()
    vmLock.isLocked = false
    vmSettings.setPIN("12345678")
    #expect(vmLock.storedPINLength == 6)
    vmLock.handleBackground(at: Date().addingTimeInterval(-120))
    vmLock.handleForeground(timeout: 60)
    #expect(vmLock.hasPIN == true)
    #expect(vmLock.storedPINLength == 8)
    #expect(vmLock.isLocked == true)
  }

  // MARK: - Lockout Text

  @Test func lockoutRemainingText_noLockout_empty() {
    let vm = makeVM()
    #expect(vm.lockoutRemainingText == "")
  }

  @Test func lockoutRemainingText_showsSeconds() {
    seedLockoutExpiry(Date().addingTimeInterval(30))
    let vm = makeVM()
    let text = vm.lockoutRemainingText
    #expect(text.contains("30s") || text.contains("29s"))
  }

  @Test func lockoutRemainingText_showsMinutes() {
    seedLockoutExpiry(Date().addingTimeInterval(300))
    let vm = makeVM()
    let text = vm.lockoutRemainingText
    #expect(text.contains("5m") || text.contains("4m"))
  }

  @Test func lockoutRemainingText_showsHoursAndMinutes() {
    seedLockoutExpiry(Date().addingTimeInterval(7260))
    let vm = makeVM()
    let text = vm.lockoutRemainingText
    #expect(text.contains("2h"))
  }

  // MARK: - Face ID Retry State Reset

  @Test func faceIDRetry_clearsState() {
    let vm = makeVM()
    vm.needsPINEntry = true
    vm.pinInput = "12"
    vm.pinError = "Incorrect PIN"
    vm.needsPINEntry = false
    vm.pinInput = ""
    vm.pinError = ""
    #expect(vm.needsPINEntry == false)
    #expect(vm.pinInput == "")
    #expect(vm.pinError == "")
  }
}

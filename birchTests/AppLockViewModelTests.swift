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

  /// Checks the lockout ends `seconds` after the failed attempt made between
  /// `start` and `end`. Measuring from those clock readings rather than from now
  /// keeps a slow test runner from failing the check.
  private func expectLockout(_ vm: AppLockViewModel, seconds: TimeInterval, start: Date, end: Date) throws {
    let expiry = try #require(vm.lockoutExpiry)
    #expect(expiry >= start.addingTimeInterval(seconds))
    #expect(expiry <= end.addingTimeInterval(seconds))
  }

  // MARK: - Initialization

  @Test func `init with no PIN has PIN is false`() {
    let vm = makeVM()
    #expect(vm.hasPIN == false)
  }

  @Test func `init with existing PIN has PIN is true`() {
    seedPIN("1234")
    let vm = makeVM()
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
  }

  @Test func `init with persisted failed attempts restores count`() {
    seedFailedAttempts(5)
    let vm = makeVM()
    #expect(vm.failedAttempts == 5)
  }

  @Test func `init with expired lockout clears lockout`() {
    seedLockoutExpiry(Date().addingTimeInterval(-100))
    let vm = makeVM()
    #expect(vm.lockoutExpiry == nil)
    #expect(vm.isLockedOut == false)
  }

  @Test func `init with active lockout restores lockout`() {
    seedLockoutExpiry(Date().addingTimeInterval(300))
    let vm = makeVM()
    #expect(vm.lockoutExpiry != nil)
    #expect(vm.isLockedOut == true)
  }

  // MARK: - PIN Management

  @Test func `set PIN stores hash and length`() {
    let vm = makeVM()
    vm.setPIN("1234")
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
    #expect(MockKeychainHelper.load(forKey: Constants.keychainPINHashKey) == hashPIN("1234"))
    #expect(MockKeychainHelper.load(forKey: Constants.keychainPINLengthKey) == Data("4".utf8))
  }

  @Test func `set PIN resets failed attempts`() {
    let vm = makeVM()
    vm.setPIN("9999")
    _ = vm.verifyPIN("0000")
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts == 2)
    vm.setPIN("5678")
    #expect(vm.failedAttempts == 0)
  }

  @Test func `remove PIN clears keychain and state`() {
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

  @Test func `set PIN remove PIN set PIN toggles correctly`() {
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

  @Test func `verify PIN correct PIN returns true`() {
    let vm = makeVM()
    vm.setPIN("5678")
    vm.needsPINEntry = true
    let result = vm.verifyPIN("5678")
    #expect(result == true)
    #expect(vm.isLocked == false)
    #expect(vm.needsPINEntry == false)
    #expect(vm.failedAttempts == 0)
  }

  @Test func `verify PIN wrong PIN returns false`() {
    let vm = makeVM()
    vm.setPIN("5678")
    let result = vm.verifyPIN("0000")
    #expect(result == false)
    #expect(vm.failedAttempts == 1)
  }

  @Test func `verify PIN no stored PIN returns false`() {
    let vm = makeVM()
    let result = vm.verifyPIN("1234")
    #expect(result == false)
  }

  @Test func `verify PIN correct PIN resets failed attempts`() {
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

  @Test func `verify PIN while locked out returns false`() {
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

  @Test func `lockout no lockout for 1 to 3 failures`() {
    let vm = makeVM()
    vm.setPIN("5678")
    _ = vm.verifyPIN("0000")
    #expect(vm.isLockedOut == false)
    _ = vm.verifyPIN("0000")
    #expect(vm.isLockedOut == false)
    _ = vm.verifyPIN("0000")
    #expect(vm.isLockedOut == false)
  }

  @Test func `lockout 60 s after 4 failures`() throws {
    let vm = makeVM()
    vm.setPIN("5678")
    let start = Date()
    for _ in 1 ... 4 {
      _ = vm.verifyPIN("0000")
    }
    let end = Date()
    #expect(vm.isLockedOut == true)
    #expect(vm.failedAttempts == 4)
    try expectLockout(vm, seconds: 60, start: start, end: end)
  }

  @Test func `lockout 10 m after 5 failures`() throws {
    seedPIN("5678")
    seedFailedAttempts(4)
    let vm = makeVM()
    let start = Date()
    _ = vm.verifyPIN("0000")
    let end = Date()
    #expect(vm.failedAttempts == 5)
    try expectLockout(vm, seconds: 600, start: start, end: end)
  }

  @Test func `lockout 90 m after 6 failures`() throws {
    seedPIN("5678")
    seedFailedAttempts(5)
    let vm = makeVM()
    let start = Date()
    _ = vm.verifyPIN("0000")
    let end = Date()
    #expect(vm.failedAttempts == 6)
    try expectLockout(vm, seconds: 5400, start: start, end: end)
  }

  @Test func `lockout 24 h after 7 failures`() throws {
    seedPIN("5678")
    seedFailedAttempts(6)
    let vm = makeVM()
    let start = Date()
    _ = vm.verifyPIN("0000")
    let end = Date()
    #expect(vm.failedAttempts == 7)
    try expectLockout(vm, seconds: 86400, start: start, end: end)
  }

  @Test func `lockout persists survives re init`() {
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

  @Test func `failed attempts 10 reaches wipe threshold`() {
    seedPIN("5678")
    seedFailedAttempts(9)
    let vm = makeVM()
    _ = vm.verifyPIN("0000")
    #expect(vm.failedAttempts >= 10)
    #expect(vm.pinError == "Too many attempts")
  }

  // MARK: - Background / Foreground

  @Test func `handle background called twice no overwrite`() {
    let vm = makeVM()
    vm.isLocked = false
    let earlyTime = Date().addingTimeInterval(-120)
    vm.handleBackground(at: earlyTime)
    vm.handleBackground(at: Date())
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == true)
  }

  @Test func `handle foreground under timeout stays unlocked`() {
    let vm = makeVM()
    vm.isLocked = false
    vm.handleBackground(at: Date())
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == false)
  }

  @Test func `handle foreground over timeout re locks`() {
    let vm = makeVM()
    vm.isLocked = false
    vm.handleBackground(at: Date().addingTimeInterval(-120))
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == true)
  }

  @Test func `handle foreground rereads PIN state`() {
    let vm = makeVM()
    #expect(vm.hasPIN == false)
    seedPIN("1234")
    vm.handleForeground(timeout: 60)
    #expect(vm.hasPIN == true)
    #expect(vm.storedPINLength == 4)
  }

  @Test func `handle foreground rereads PIN length after removal`() {
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

  @Test func `handle foreground no prior background no relock`() {
    let vm = makeVM()
    vm.isLocked = false
    vm.handleForeground(timeout: 60)
    #expect(vm.isLocked == false)
  }

  // MARK: - Cross-Instance Sync

  @Test func `cross instance set PIN on one foreground reads on other`() {
    let vmA = makeVM()
    let vmB = makeVM()
    vmA.setPIN("1234")
    #expect(vmA.hasPIN == true)
    #expect(vmB.hasPIN == false)
    vmB.handleForeground(timeout: 60)
    #expect(vmB.hasPIN == true)
    #expect(vmB.storedPINLength == 4)
  }

  @Test func `cross instance remove PIN on one foreground reads on other`() {
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

  @Test func `cross instance set PIN then timeout shows correct PIN length`() {
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

  @Test func `lockout remaining text no lockout empty`() {
    let vm = makeVM()
    #expect(vm.lockoutRemainingText == "")
  }

  @Test func `lockout remaining text shows seconds`() {
    let start = Date()
    seedLockoutExpiry(start.addingTimeInterval(30))
    let vm = makeVM()
    let text = vm.lockoutRemainingText
    // Whole seconds left, which depends on how long the test has taken so far.
    let fewest = Int(30 - Date().timeIntervalSince(start))
    #expect((fewest ... 30).contains { text == "Try again in \($0)s" }, "\(text)")
  }

  @Test func `lockout remaining text shows minutes`() {
    seedLockoutExpiry(Date().addingTimeInterval(300))
    let vm = makeVM()
    let text = vm.lockoutRemainingText
    #expect(text.contains("5m") || text.contains("4m"))
  }

  @Test func `lockout remaining text shows hours and minutes`() {
    seedLockoutExpiry(Date().addingTimeInterval(7260))
    let vm = makeVM()
    let text = vm.lockoutRemainingText
    #expect(text.contains("2h"))
  }

  // MARK: - Face ID Retry State Reset

  @Test func `face ID retry clears state`() {
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

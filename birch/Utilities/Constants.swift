import Foundation

enum Constants {
  // MARK: - App

  static let appName = "Birch"
  static let defaultNetwork: BitcoinNetwork = .testnet4

  // MARK: - BIP48 P2WSH

  static let bip48ScriptType = 2 // P2WSH native segwit
  static let defaultDerivationPathMainnet = "m/48'/0'/0'/2'"
  static let defaultDerivationPathTestnet = "m/48'/1'/0'/2'"

  // MARK: - UserDefaults Keys

  static let activeWalletIDKey = "activeWalletID"
  static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
  static let autoRefreshEnabledKey = "autoRefreshEnabled"
  static let autoRefreshIntervalKey = "autoRefreshInterval"
  static let denominationKey = "denomination"
  static let appLockEnabledKey = "appLockEnabled"
  static let fiatEnabledKey = "fiatEnabled"
  static let fiatCurrencyKey = "fiatCurrency"
  static let fiatPrimaryKey = "fiatPrimary"
  static let fiatSourceKey = "fiatSource"
  static let feeSourceKey = "feeSource"
  static let qrEncodingKey = "qrEncoding"
  static let qrDensityKey = "qrDensity"
  static let qrFrameRateKey = "qrFrameRate"
  static let psbtCompactKey = "psbtCompactQR"
  static let themeKey = "appTheme"
  static let appLockTimeoutKey = "appLockTimeout"
  static let appLockPINEnabledKey = "appLockPINEnabled"

  // MARK: - Keychain Keys

  static let keychainPINHashKey = "com.birch.pin.hash"
  static let keychainPINLengthKey = "com.birch.pin.length"
  static let keychainFailedAttemptsKey = "com.birch.pin.failedAttempts"
  static let keychainLockoutExpiryKey = "com.birch.pin.lockoutExpiry"

  /// Available auto-refresh intervals in seconds
  static let autoRefreshStops: [Double] = [30, 60, 120, 300, 600]

  // MARK: - Wallet Storage

  static let walletsDirName = "wallets"
  static let bdkDatabaseFilename = "bdk_wallet.sqlite"

  // MARK: - Limits

  static let maxCosigners = 10
  static let minCosigners = 1
  static let maxAddressGap = 20

  static func derivationPath(for network: BitcoinNetwork) -> String {
    "m/48'/\(network.coinType)'/0'/2'"
  }

  static func walletsDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent(walletsDirName)
  }

  static func walletDirectory(for walletID: UUID) -> URL {
    walletsDirectory().appendingPathComponent(walletID.uuidString)
  }

  static func walletDatabasePath(for walletID: UUID) -> URL {
    walletDirectory(for: walletID).appendingPathComponent(bdkDatabaseFilename)
  }

  // MARK: - Privacy Mode

  private static let privacySymbols: [Character] = [
    "⠁", "⠃", "⠉", "⠙", "⠑", "⠋", "⠛", "⠓", "⠊", "⠚",
    "⠅", "⠇", "⠍", "⠝", "⠕", "⠏", "⠟", "⠗", "⠎", "⠞",
    "⠥", "⠧", "⠺", "⠭", "⠽", "⠵",
  ]

  static func privacyText(length: Int = 5) -> String {
    String((0 ..< length).map { _ in privacySymbols.randomElement()! })
  }
}

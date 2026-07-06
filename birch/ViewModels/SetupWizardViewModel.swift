import BitcoinDevKit
import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class SetupWizardViewModel {
  private let logger = AppLog(.wizard)

  enum Step: Int, CaseIterable {
    case welcome
    case creationChoice
    case multisigConfig
    case cosignerImport
    case descriptorImport
    case walletName
    case review
    case verify
  }

  enum CreationMode {
    case createNew
    case importDescriptor
  }

  // Navigation
  var currentStep: Step = .welcome
  var creationMode: CreationMode = .createNew

  // Multisig config
  var requiredSignatures: Int = 2
  var totalCosigners: Int = 3

  // Cosigner data
  var cosignerLabels: [String] = []
  var cosignerXpubs: [String] = []
  var cosignerFingerprints: [String] = []
  var cosignerDerivationPaths: [String] = []
  var currentCosignerIndex: Int = 0

  /// Import
  var importedDescriptorText: String = ""

  /// Wallet name
  var walletName: String = ""

  // Computed descriptors
  var externalDescriptor: String = ""
  var internalDescriptor: String = ""

  // Verification step
  var firstReceiveAddress: String = ""
  var addressDerivationError: String?

  // Electrum server
  var electrumHost: String = ""
  var electrumPort: String = ""
  var electrumSSL: Int = 0 // 0 = network default, 1 = TCP, 2 = SSL
  var electrumAllowInsecureSSL: Bool = false

  /// Returns an error message if the descriptor contains keys that don't match the selected network, nil otherwise.
  var descriptorNetworkMismatchError: String? {
    let text = importedDescriptorText
    guard !text.isEmpty else { return nil }

    let hasTestnetKeys = text.contains("tpub") || text.contains("Vpub")
    let hasMainnetKeys = text.contains("xpub") || text.contains("Zpub")

    if network == .mainnet, hasTestnetKeys, !hasMainnetKeys {
      return "Testnet descriptors cannot be used on mainnet"
    }
    if network != .mainnet, hasMainnetKeys, !hasTestnetKeys {
      return "Mainnet descriptors cannot be used on testnet/signet"
    }
    return nil
  }

  var isElectrumHostRequired: Bool {
    network.defaultElectrumHost == nil
  }

  var isElectrumHostValid: Bool {
    !isElectrumHostRequired || !electrumHost.trimmingCharacters(in: .whitespaces).isEmpty
  }

  // Advanced settings
  var blockExplorerHost: String = ""
  var addressGapLimit: String = "20"

  // State
  var errorMessage: String?
  var importDescriptorError: String?
  var isProcessing: Bool = false
  var network: BitcoinNetwork = .testnet4
  /// Set to true after the wallet has been created during the import flow.
  var walletCreated: Bool = false

  /// Progress
  var stepCount: Int {
    creationMode == .createNew ? 6 : 3
  }

  var currentStepIndex: Int {
    switch currentStep {
    case .welcome: 0
    case .creationChoice: 1
    case .multisigConfig: 2
    case .cosignerImport: 3
    case .descriptorImport: 2
    case .walletName: creationMode == .createNew ? 4 : 3
    case .review: stepCount - 1
    case .verify: stepCount - 1
    }
  }

  var progress: Double {
    Double(currentStepIndex) / Double(stepCount - 1)
  }

  // MARK: - Cosigner Management

  func initializeCosigners() {
    let count = totalCosigners
    cosignerLabels = (0 ..< count).map { "Cosigner \($0 + 1)" }
    cosignerXpubs = Array(repeating: "", count: count)
    cosignerFingerprints = Array(repeating: "", count: count)
    cosignerDerivationPaths = Array(repeating: Constants.derivationPath(for: network), count: count)
    currentCosignerIndex = 0
  }

  var allCosignersComplete: Bool {
    cosignerXpubs.allSatisfy { !$0.isEmpty }
      && cosignerFingerprints.allSatisfy { !$0.isEmpty }
  }

  var currentCosignerComplete: Bool {
    guard currentCosignerIndex < cosignerXpubs.count else { return false }
    return !cosignerXpubs[currentCosignerIndex].isEmpty
      && !cosignerFingerprints[currentCosignerIndex].isEmpty
  }

  // MARK: - Validation

  func validateCosignerXpub(_ xpub: String, at index: Int) -> String? {
    if xpub.isEmpty { return "Xpub is required" }

    let expectedPrefixes = network == .mainnet ? ["xpub", "Zpub"] : ["tpub", "Vpub"]
    if !expectedPrefixes.contains(where: { xpub.hasPrefix($0) }) {
      return "Expected \(expectedPrefixes.joined(separator: " or ")) prefix for \(network.displayName)"
    }

    // Check for duplicates
    for (i, existing) in cosignerXpubs.enumerated() where i != index {
      if !existing.isEmpty, existing == xpub {
        return "Duplicate xpub (same as Cosigner \(i + 1))"
      }
    }

    return nil
  }

  func validateDerivationPath(_ path: String) -> String? {
    SetupWizardViewModel.validateDerivationPath(path, for: network)
  }

  static func validateDerivationPath(_ path: String, for network: BitcoinNetwork) -> String? {
    let bip48Pattern = #"^m/48'/[01]'/\d+'/2'$"#
    guard path.range(of: bip48Pattern, options: .regularExpression) != nil else {
      return "Invalid derivation path. Expected BIP48 format: \(Constants.derivationPath(for: network))"
    }
    // components: ["m", "48'", "<coinType>'", "<account>'", "2'"]
    let components = path.split(separator: "/")
    guard components.count == 5 else {
      return "Invalid derivation path structure"
    }
    let coinTypeComponent = String(components[2]) // e.g. "0'" or "1'"
    let expectedCoinType = "\(network.coinType)'"
    if coinTypeComponent != expectedCoinType {
      let pathNetwork = coinTypeComponent == "0'" ? "mainnet" : "testnet/signet"
      return "Derivation path coin type is for \(pathNetwork) but wallet network is \(network.displayName). Expected \(Constants.derivationPath(for: network))."
    }
    let accountComponent = String(components[3]) // e.g. "0'" or "1'"
    if accountComponent != "0'" {
      return "Birch only supports account 0 (\(Constants.derivationPath(for: network))). This key uses account \(accountComponent.dropLast())."
    }
    return nil
  }

  func validateFingerprint(_ fp: String) -> String? {
    if fp.isEmpty { return "Fingerprint is required" }
    if fp.count != 8 { return "Fingerprint must be 8 hex characters" }
    if !fp.allSatisfy(\.isHexDigit) { return "Fingerprint must be hex characters only" }
    return nil
  }

  // MARK: - Descriptor Building

  func buildDescriptors() {
    guard allCosignersComplete else { return }

    // Build key origin strings — normalize to standard xpub/tpub format before
    // sorting so BIP67 ordering matches what's emitted in the descriptor.
    let isTestnet = network != .mainnet
    var keyEntries: [(origin: String, xpub: String, fingerprint: String, path: String, label: String, index: Int)] = []

    for i in 0 ..< totalCosigners {
      let raw = cosignerXpubs[i].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let normalized = URService.normalizeXpub(raw, isTestnet: isTestnet) ?? raw
      keyEntries.append((
        origin: "[\(cosignerFingerprints[i])/48'/\(network.coinType)'/0'/2']",
        xpub: normalized,
        fingerprint: cosignerFingerprints[i],
        path: cosignerDerivationPaths[i],
        label: cosignerLabels[i],
        index: i
      ))
    }

    // Sort by xpub for BIP67 compliance
    keyEntries.sort { $0.xpub < $1.xpub }

    let externalKeys = keyEntries.map {
      "\($0.origin)\($0.xpub)/0/*"
    }.joined(separator: ",")
    let internalKeys = keyEntries.map {
      "\($0.origin)\($0.xpub)/1/*"
    }.joined(separator: ",")

    externalDescriptor = "wsh(sortedmulti(\(requiredSignatures),\(externalKeys)))"
    internalDescriptor = "wsh(sortedmulti(\(requiredSignatures),\(internalKeys)))"
    logger.info("Built \(requiredSignatures)-of-\(totalCosigners) descriptors on \(network.displayName): \(externalDescriptor)")
  }

  var combinedDescriptor: String {
    let cosignerData = (0 ..< totalCosigners).map {
      (xpub: cosignerXpubs[$0], fingerprint: cosignerFingerprints[$0], derivationPath: cosignerDerivationPaths[$0])
    }
    return BitcoinService.buildCombinedDescriptor(
      requiredSignatures: requiredSignatures,
      cosigners: cosignerData,
      network: network
    )
  }

  func deriveFirstAddress() {
    let bdkNetwork = BitcoinService.shared.bdkNetwork(from: network)
    let bdkNetworkKind = BitcoinService.shared.bdkNetworkKind(from: network)
    do {
      let extDesc = try Descriptor(descriptor: externalDescriptor, networkKind: bdkNetworkKind)
      let chgDesc = try Descriptor(descriptor: internalDescriptor, networkKind: bdkNetworkKind)
      let persister = try Persister.newInMemory()
      let tempWallet = try Wallet(
        descriptor: extDesc,
        changeDescriptor: chgDesc,
        network: bdkNetwork,
        persister: persister
      )
      let info = tempWallet.peekAddress(keychain: .external, index: 0)
      firstReceiveAddress = info.address.description
      addressDerivationError = nil
    } catch {
      addressDerivationError = "Failed to derive address: \(error.localizedDescription)"
      firstReceiveAddress = ""
    }
  }

  func parseImportedDescriptor() -> Bool {
    // If the input is a JSON object (e.g. Specter Desktop export), extract the descriptor field
    if let descriptor = URService.extractDescriptorFromJSON(importedDescriptorText) {
      importedDescriptorText = descriptor
    }

    // Remove all whitespace and newlines — descriptors may be pasted in multiline format
    var text = importedDescriptorText.components(separatedBy: .whitespacesAndNewlines).joined()
    guard !text.isEmpty else {
      errorMessage = "Descriptor is empty"
      return false
    }

    // Strip checksum (e.g. #2kjudevd)
    if let hashIndex = text.lastIndex(of: "#") {
      text = String(text[text.startIndex ..< hashIndex])
    }

    // Normalize smart/curly quotes to ASCII apostrophes (iOS keyboard substitution)
    for smartQuote in ["\u{2018}", "\u{2019}", "\u{02BC}"] {
      text = text.replacingOccurrences(of: smartQuote, with: "'")
    }

    // Normalize hardened notation: h → '
    text = text.replacingOccurrences(of: "h/", with: "'/")
    text = text.replacingOccurrences(of: "h]", with: "']")
    text = text.replacingOccurrences(of: "h)", with: "')")

    // Basic validation - check it starts with wsh(sortedmulti(
    guard text.hasPrefix("wsh(sortedmulti(") else {
      errorMessage = "Descriptor must be wsh(sortedmulti(...)) format"
      return false
    }

    // Extract M value
    let afterPrefix = text.dropFirst("wsh(sortedmulti(".count)
    guard let commaIndex = afterPrefix.firstIndex(of: ",") else {
      errorMessage = "Cannot parse M value from descriptor"
      return false
    }
    guard let m = Int(afterPrefix[afterPrefix.startIndex ..< commaIndex]) else {
      errorMessage = "Invalid M value"
      return false
    }

    // Handle BIP-389 multipath descriptors: /<0;1>/* → split into /0/* and /1/*
    if text.contains("<0;1>/*") {
      externalDescriptor = text.replacingOccurrences(of: "<0;1>/*", with: "0/*")
      internalDescriptor = text.replacingOccurrences(of: "<0;1>/*", with: "1/*")
    } else if text.contains("<1;0>/*") {
      externalDescriptor = text.replacingOccurrences(of: "<1;0>/*", with: "0/*")
      internalDescriptor = text.replacingOccurrences(of: "<1;0>/*", with: "1/*")
    } else if text.contains("{0,1}/*") {
      // Pre-BIP389 Specter DIY format: {0,1}/* → split into /0/* and /1/*
      externalDescriptor = text.replacingOccurrences(of: "{0,1}/*", with: "0/*")
      internalDescriptor = text.replacingOccurrences(of: "{0,1}/*", with: "1/*")
    } else if text.contains("{1,0}/*") {
      externalDescriptor = text.replacingOccurrences(of: "{1,0}/*", with: "0/*")
      internalDescriptor = text.replacingOccurrences(of: "{1,0}/*", with: "1/*")
    } else if text.contains("/0/*") {
      // Standard single-path descriptor (external)
      externalDescriptor = text
      internalDescriptor = text.replacingOccurrences(of: "/0/*", with: "/1/*")
    } else if text.contains("/1/*") {
      // Standard single-path descriptor (internal)
      internalDescriptor = text
      externalDescriptor = text.replacingOccurrences(of: "/1/*", with: "/0/*")
    } else {
      // No derivation suffix (e.g. Specter Desktop format) — append /0/* and /1/*
      // Replace each bare xpub (followed by , or )) with xpub/0/* for external
      let xpubPattern = #"([xt]pub[a-zA-Z0-9]+)(?=[,)])"#
      if let xpubRegex = try? NSRegularExpression(pattern: xpubPattern) {
        let nsText = text as NSString
        externalDescriptor = xpubRegex.stringByReplacingMatches(
          in: text, range: NSRange(location: 0, length: nsText.length),
          withTemplate: "$1/0/*"
        )
        internalDescriptor = xpubRegex.stringByReplacingMatches(
          in: text, range: NSRange(location: 0, length: nsText.length),
          withTemplate: "$1/1/*"
        )
      } else {
        externalDescriptor = text
        internalDescriptor = text
      }
    }

    // Parse cosigner info from key origins
    // Supports both ' and h for hardened notation (already normalized to ' above)
    let pattern = #"\[([0-9a-fA-F]{8})/48'/([01])'/(\d+)'/2'\]([xt]pub[a-zA-Z0-9]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      errorMessage = "Failed to parse cosigner keys"
      return false
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

    if matches.isEmpty {
      errorMessage = "No cosigner keys found in descriptor"
      return false
    }

    // Every key must carry BIP48 origin info — otherwise keys without an origin
    // would be silently dropped and the cosigner count would be wrong.
    // Keys always follow "," (no origin) or "]" (after origin), which cannot
    // occur inside a base58 key body, so this counts keys without false matches.
    let keyPattern = #"[,\]][xt]pub"#
    if let keyRegex = try? NSRegularExpression(pattern: keyPattern) {
      let keyCount = keyRegex.numberOfMatches(in: text, range: NSRange(location: 0, length: nsText.length))
      if keyCount != matches.count {
        errorMessage = "All keys must include BIP48 origin info like [fingerprint/48'/\(network.coinType)'/0'/2']"
        return false
      }
    }

    // Validate each key's origin path (coin type must match the network, account must be 0)
    for match in matches {
      let coin = nsText.substring(with: match.range(at: 2))
      let account = nsText.substring(with: match.range(at: 3))
      if let error = Self.validateDerivationPath("m/48'/\(coin)'/\(account)'/2'", for: network) {
        errorMessage = error
        return false
      }
    }

    requiredSignatures = m
    totalCosigners = matches.count

    cosignerLabels = []
    cosignerXpubs = []
    cosignerFingerprints = []
    cosignerDerivationPaths = []

    for (i, match) in matches.enumerated() {
      let fp = nsText.substring(with: match.range(at: 1))
      let coin = nsText.substring(with: match.range(at: 2))
      let account = nsText.substring(with: match.range(at: 3))
      let xpub = nsText.substring(with: match.range(at: 4))

      cosignerLabels.append("Cosigner \(i + 1)")
      cosignerFingerprints.append(fp)
      cosignerXpubs.append(xpub)
      cosignerDerivationPaths.append("m/48'/\(coin)'/\(account)'/2'")
    }

    if requiredSignatures > totalCosigners {
      errorMessage = "M (\(requiredSignatures)) cannot be greater than N (\(totalCosigners))"
      return false
    }

    return true
  }

  // MARK: - Navigation

  func goToNext() {
    let fromStep = currentStep
    defer {
      if currentStep != fromStep {
        logger.info("Wizard step: \(fromStep) -> \(currentStep)")
      }
    }
    switch currentStep {
    case .welcome:
      currentStep = .creationChoice
    case .creationChoice:
      if creationMode == .createNew {
        currentStep = .multisigConfig
      } else {
        currentStep = .descriptorImport
      }
    case .multisigConfig:
      guard isElectrumHostValid else {
        errorMessage = "An Electrum server host is required for \(network.displayName)"
        return
      }
      initializeCosigners()
      currentStep = .cosignerImport
    case .cosignerImport:
      buildDescriptors()
      currentStep = .walletName
    case .descriptorImport:
      importDescriptorError = nil
      guard isElectrumHostValid else {
        importDescriptorError = "An Electrum server host is required for \(network.displayName)"
        return
      }
      guard parseImportedDescriptor() else {
        importDescriptorError = errorMessage
        errorMessage = nil
        return
      }
      // Validate descriptors with BDK before proceeding
      let bdkNetworkKind = BitcoinService.shared.bdkNetworkKind(from: network)
      do {
        _ = try Descriptor(descriptor: externalDescriptor, networkKind: bdkNetworkKind)
        _ = try Descriptor(descriptor: internalDescriptor, networkKind: bdkNetworkKind)
        logger.info("Imported descriptor validated: \(externalDescriptor)")
      } catch {
        logger.error("Imported descriptor invalid: \(error.localizedDescription)")
        importDescriptorError = "Invalid descriptor: \(error.localizedDescription)"
        return
      }
      currentStep = .walletName
    case .walletName:
      deriveFirstAddress()
      currentStep = .verify
    case .review:
      break // unused in current flow
    case .verify:
      break // handled by saveWallet
    }
  }

  func goBack() {
    switch currentStep {
    case .welcome: break
    case .creationChoice: currentStep = .welcome
    case .multisigConfig: currentStep = .creationChoice
    case .cosignerImport: currentStep = .multisigConfig
    case .descriptorImport: currentStep = .creationChoice
    case .walletName:
      if creationMode == .createNew {
        currentStep = .cosignerImport
      }
    // Import flow: back button is hidden, wallet already created
    case .review: currentStep = .walletName
    case .verify: currentStep = .walletName
    }
  }

  // MARK: - Save

  func saveWallet(modelContext: ModelContext) throws {
    guard isElectrumHostValid else {
      throw AppError.electrumConnectionFailed("An Electrum server host is required for \(network.displayName)")
    }

    // Validate descriptors with BDK before saving — catch parse errors early
    let bdkNetworkKind = BitcoinService.shared.bdkNetworkKind(from: network)
    do {
      _ = try Descriptor(descriptor: externalDescriptor, networkKind: bdkNetworkKind)
      _ = try Descriptor(descriptor: internalDescriptor, networkKind: bdkNetworkKind)
    } catch {
      logger.error("Descriptor validation failed while saving wallet: \(error.localizedDescription)")
      throw AppError.descriptorInvalid("\(error.localizedDescription)")
    }

    // Deactivate all existing wallets
    let fetchDescriptor = FetchDescriptor<WalletProfile>()
    let existingWallets = try modelContext.fetch(fetchDescriptor)
    for wallet in existingWallets {
      wallet.isActive = false
    }

    // Create new wallet
    let profile = WalletProfile(
      name: walletName.isEmpty ? "My Wallet" : walletName,
      requiredSignatures: requiredSignatures,
      totalCosigners: totalCosigners,
      externalDescriptor: externalDescriptor,
      internalDescriptor: internalDescriptor,
      network: network,
      isActive: true,
      addressGapLimit: Int(addressGapLimit) ?? 50,
      electrumHost: electrumHost.trimmingCharacters(in: .whitespaces),
      electrumPort: Int(electrumPort) ?? 0,
      electrumSSL: electrumSSL,
      electrumAllowInsecureSSL: electrumAllowInsecureSSL,
      blockExplorerHost: blockExplorerHost.trimmingCharacters(in: .whitespaces)
    )

    modelContext.insert(profile)

    // Create cosigner records
    for i in 0 ..< totalCosigners {
      let cosigner = CosignerInfo(
        label: cosignerLabels[i],
        xpub: cosignerXpubs[i],
        fingerprint: cosignerFingerprints[i],
        derivationPath: cosignerDerivationPaths[i],
        orderIndex: i
      )
      cosigner.wallet = profile
      modelContext.insert(cosigner)
    }

    // Set UserDefaults before save so both are in place if app is killed after save
    UserDefaults.standard.set(profile.id.uuidString, forKey: Constants.activeWalletIDKey)
    UserDefaults.standard.set(true, forKey: Constants.hasCompletedOnboardingKey)

    do {
      try modelContext.save()
      logger.info(
        "Saved new \(requiredSignatures)-of-\(totalCosigners) wallet '\(profile.name)' (\(profile.id)) "
          + "on \(network.displayName) via \(creationMode == .createNew ? "new wallet" : "descriptor import")"
      )
    } catch {
      // Rollback UserDefaults if save fails
      UserDefaults.standard.removeObject(forKey: Constants.activeWalletIDKey)
      UserDefaults.standard.removeObject(forKey: Constants.hasCompletedOnboardingKey)
      logger.error("Failed to save new wallet '\(profile.name)': \(error.localizedDescription)")
      throw error
    }
  }
}

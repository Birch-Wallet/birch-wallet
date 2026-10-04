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
    if let error = Self.validateXpub(xpub, for: network) {
      return error
    }

    // Check for duplicates in standard form, so a Vpub and its tpub count as the same key
    let isTestnet = network != .mainnet
    let canonical = URService.canonicalXpub(xpub, isTestnet: isTestnet)
    for (i, existing) in cosignerXpubs.enumerated() where i != index {
      if !existing.isEmpty, URService.canonicalXpub(existing, isTestnet: isTestnet) == canonical {
        return "Duplicate xpub (same as Cosigner \(i + 1))"
      }
    }

    return nil
  }

  /// Returns an error message unless the text is exactly one extended public key
  /// for the network (surrounding whitespace is ignored) that sits where a BIP48
  /// P2WSH key does, nil when it is valid.
  ///
  /// Pass `checkingPlacement: false` only for a key that is already part of a saved
  /// wallet: wallets created before this rule are not re-checked.
  static func validateXpub(_ xpub: String, for network: BitcoinNetwork, checkingPlacement: Bool = true) -> String? {
    let key = xpub.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty {
      return "Xpub is required"
    }

    let expectedPrefixes = network == .mainnet ? ["xpub", "Zpub"] : ["tpub", "Vpub"]
    if !expectedPrefixes.contains(where: { key.hasPrefix($0) }) {
      return "Expected \(expectedPrefixes.joined(separator: " or ")) prefix for \(network.displayName)"
    }

    // The key text goes into the descriptor, so it must decode as a single key:
    // anything after it (a path, a comma, another key) would change the wallet.
    guard let placement = URService.extendedPublicKeyPlacement(key) else {
      return "Not a valid extended public key. Enter the whole key with nothing before or after it."
    }

    // Every cosigner is pinned to m/48'/coin'/0'/2'. A key records how many steps it
    // is from the master key and the last step taken, so a key at that path is four
    // steps down with a last step of 2'. The earlier steps (48', coin, account) leave
    // no trace in a public key; only the signer can vouch for those.
    if checkingPlacement {
      let origin = PSBTGroundTruth.accountOrigin(for: network)
      if Int(placement.depth) != origin.count || placement.childNumber != origin.last {
        let hardened: UInt32 = 0x8000_0000
        let lastStep = placement.childNumber >= hardened
          ? "\(placement.childNumber - hardened)'"
          : "\(placement.childNumber)"
        return "This key is not at \(Constants.derivationPath(for: network)). A key at that path is "
          + "\(origin.count) steps from the master key with a last step of 2'; this one is "
          + "\(placement.depth) steps with a last step of \(lastStep). Export the multisig (P2WSH) key from the signer."
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
    if fp.isEmpty {
      return "Fingerprint is required"
    }
    if fp.count != 8 {
      return "Fingerprint must be 8 hex characters"
    }
    if !fp.allSatisfy(\.isHexDigit) {
      return "Fingerprint must be hex characters only"
    }
    return nil
  }

  // MARK: - Descriptor Building

  private var cosignerData: [(xpub: String, fingerprint: String, derivationPath: String)] {
    (0 ..< totalCosigners).map {
      (xpub: cosignerXpubs[$0], fingerprint: cosignerFingerprints[$0], derivationPath: cosignerDerivationPaths[$0])
    }
  }

  /// Builds both descriptors from the cosigner list. Returns false, leaving the
  /// descriptors empty and `errorMessage` set, when they cannot be built.
  @discardableResult
  func buildDescriptors() -> Bool {
    externalDescriptor = ""
    internalDescriptor = ""

    guard allCosignersComplete else {
      errorMessage = "Every cosigner needs an xpub and a fingerprint"
      return false
    }

    // Each screen validates its own cosigner; check them all again here, so the
    // descriptors can only be built from keys at the standard BIP48 path whichever
    // way the list was filled in
    for i in 0 ..< totalCosigners {
      let problem = validateCosignerXpub(cosignerXpubs[i], at: i)
        ?? validateFingerprint(cosignerFingerprints[i])
        ?? validateDerivationPath(cosignerDerivationPaths[i])
      if let problem {
        errorMessage = "Cosigner \(i + 1): \(problem)"
        return false
      }
    }

    do {
      let external = try BitcoinService.buildDescriptor(
        requiredSignatures: requiredSignatures, cosigners: cosignerData, network: network, isChange: false
      )
      let change = try BitcoinService.buildDescriptor(
        requiredSignatures: requiredSignatures, cosigners: cosignerData, network: network, isChange: true
      )
      externalDescriptor = external
      internalDescriptor = change
    } catch {
      logger.error("Failed to build descriptors: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      return false
    }

    logger.info("Built \(requiredSignatures)-of-\(totalCosigners) descriptors on \(network.displayName): \(externalDescriptor)")
    return true
  }

  var combinedDescriptor: String {
    let combined = try? BitcoinService.buildCombinedDescriptor(
      requiredSignatures: requiredSignatures,
      cosigners: cosignerData,
      network: network
    )
    return combined ?? ""
  }

  /// Addresses at the first `count` indexes of the receive chain, then of the
  /// change chain, from a throwaway in-memory wallet.
  private func peekAddresses(external: String, change: String, count: UInt32) throws -> [String] {
    let bdkNetworkKind = BitcoinService.shared.bdkNetworkKind(from: network)
    let tempWallet = try Wallet(
      descriptor: Descriptor(descriptor: external, networkKind: bdkNetworkKind),
      changeDescriptor: Descriptor(descriptor: change, networkKind: bdkNetworkKind),
      network: BitcoinService.shared.bdkNetwork(from: network),
      persister: Persister.newInMemory()
    )
    return [KeychainKind.external, .internal].flatMap { keychain in
      (0 ..< count).map { tempWallet.peekAddress(keychain: keychain, index: $0).address.description }
    }
  }

  func deriveFirstAddress() {
    do {
      firstReceiveAddress = try peekAddresses(external: externalDescriptor, change: internalDescriptor, count: 1)[0]
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
    text = Self.normalizeHardenedNotation(text)

    // Birch is watch-only: refuse a descriptor carrying a private key before any
    // of it is parsed, stored or logged. A key starts after "(", "," or "]", none
    // of which occur inside a base58 key, so a public key cannot match.
    if text.range(of: #"[,(\]][A-Za-z]prv"#, options: .regularExpression) != nil {
      errorMessage = "This descriptor contains a private key. Birch is watch-only: import the public descriptor, with xpub or tpub keys only."
      return false
    }

    // The whole text must be a single wsh(sortedmulti(...)) with nothing after it
    let prefix = "wsh(sortedmulti("
    guard text.hasPrefix(prefix), text.hasSuffix("))"),
          let arguments = Self.splitDescriptorArguments(text.dropFirst(prefix.count).dropLast(2))
    else {
      errorMessage = "Descriptor must be wsh(sortedmulti(...)) format"
      return false
    }

    // Extract M value
    guard arguments.count > 1 else {
      errorMessage = "Cannot parse M value from descriptor"
      return false
    }
    guard let m = Int(arguments[0]), m > 0 else {
      errorMessage = "Invalid M value"
      return false
    }

    // Every argument after M must be one key in the form Birch supports — a BIP48
    // origin, an xpub/tpub and an optional receive/change suffix — matched in full,
    // so nothing in the descriptor goes unread.
    // Supports both ' and h for hardened notation (already normalized to ' above)
    let keyPattern = #"^\[([0-9a-fA-F]{8})/48'/([01])'/(\d+)'/2'\]([xt]pub[a-zA-Z0-9]+)(.*)$"#
    guard let keyRegex = try? NSRegularExpression(pattern: keyPattern) else {
      errorMessage = "Failed to parse cosigner keys"
      return false
    }

    var keys: [(xpub: String, fingerprint: String, derivationPath: String)] = []
    var suffixes: Set<String> = []

    for (i, argument) in arguments.dropFirst().enumerated() {
      let nsArgument = argument as NSString
      guard let match = keyRegex.firstMatch(in: argument, range: NSRange(location: 0, length: nsArgument.length)) else {
        // Bare xpubs, raw public keys and non-BIP48 origins all end up here
        errorMessage = "All keys must include BIP48 origin info like [fingerprint/48'/\(network.coinType)'/0'/2']"
        return false
      }

      let fingerprint = nsArgument.substring(with: match.range(at: 1))
      let coin = nsArgument.substring(with: match.range(at: 2))
      let account = nsArgument.substring(with: match.range(at: 3))
      let xpub = nsArgument.substring(with: match.range(at: 4))
      let suffix = nsArgument.substring(with: match.range(at: 5))
      let derivationPath = "m/48'/\(coin)'/\(account)'/2'"

      // Validate the key's origin path (coin type must match the network, account must be 0)
      if let error = Self.validateDerivationPath(derivationPath, for: network) {
        errorMessage = error
        return false
      }
      if let error = Self.validateXpub(xpub, for: network) {
        errorMessage = "Key \(i + 1): \(error)"
        return false
      }
      guard Self.importableKeySuffixes.contains(suffix) else {
        errorMessage = "Key \(i + 1) has a derivation suffix Birch does not support. Use /<0;1>/*, /0/*, /1/* or no suffix."
        return false
      }

      keys.append((xpub: xpub, fingerprint: fingerprint, derivationPath: derivationPath))
      suffixes.insert(suffix)
    }

    guard suffixes.count == 1 else {
      errorMessage = "All keys must use the same derivation suffix"
      return false
    }

    guard Set(keys.map(\.xpub)).count == keys.count else {
      errorMessage = "The same key appears more than once in the descriptor"
      return false
    }

    if m > keys.count {
      errorMessage = "M (\(m)) cannot be greater than N (\(keys.count))"
      return false
    }

    // Store the descriptor the cosigner list describes, rebuilt from the parsed
    // keys, rather than the pasted text — so the wallet, the cosigners shown and
    // the exported backup cannot differ. As a backstop, the rebuilt descriptors
    // must give the same addresses as the text as it was imported.
    let canonicalExternal: String
    let canonicalInternal: String
    do {
      canonicalExternal = try BitcoinService.buildDescriptor(
        requiredSignatures: m, cosigners: keys, network: network, isChange: false
      )
      canonicalInternal = try BitcoinService.buildDescriptor(
        requiredSignatures: m, cosigners: keys, network: network, isChange: true
      )

      let imported = Self.splitImportedDescriptor(text)
      let canonicalAddresses = try peekAddresses(external: canonicalExternal, change: canonicalInternal, count: 3)
      let importedAddresses = try peekAddresses(external: imported.external, change: imported.change, count: 3)
      guard canonicalAddresses == importedAddresses else {
        logger.error("Imported descriptor rejected: addresses differ from the descriptor rebuilt from its cosigner keys")
        errorMessage = "This descriptor does not match the cosigner keys read from it, so it was not imported. "
          + "Expected wsh(sortedmulti(M,[fingerprint/48'/\(network.coinType)'/0'/2']xpub/<0;1>/*,...))"
        return false
      }
    } catch let error as AppError {
      errorMessage = error.localizedDescription
      return false
    } catch {
      errorMessage = "Invalid descriptor: \(error.localizedDescription)"
      return false
    }

    externalDescriptor = canonicalExternal
    internalDescriptor = canonicalInternal

    requiredSignatures = m
    totalCosigners = keys.count

    cosignerLabels = keys.indices.map { "Cosigner \($0 + 1)" }
    cosignerXpubs = keys.map(\.xpub)
    cosignerFingerprints = keys.map(\.fingerprint)
    cosignerDerivationPaths = keys.map(\.derivationPath)

    return true
  }

  /// Rewrites hardened notation (h → ') inside key origins ([fingerprint/48h/...]) only.
  /// A base58 key can end in "h", so an "h" outside the brackets is part of a key.
  /// One pass over the text, so a very long pasted or scanned input stays cheap.
  private static func normalizeHardenedNotation(_ text: String) -> String {
    let characters = Array(text)
    var result = ""
    var insideOrigin = false

    for (i, character) in characters.enumerated() {
      if character == "[" {
        insideOrigin = true
      } else if character == "]" {
        insideOrigin = false
      }

      let next = i + 1 < characters.count ? characters[i + 1] : nil
      if insideOrigin, character == "h", next == "/" || next == "]" {
        result.append("'")
      } else {
        result.append(character)
      }
    }

    return result
  }

  /// Key suffixes accepted on import. Every key in a descriptor must use the same one.
  private static let importableKeySuffixes: Set<String> = [
    "", "/<0;1>/*", "/<1;0>/*", "/{0,1}/*", "/{1,0}/*", "/0/*", "/1/*",
  ]

  /// Splits the arguments of a descriptor function on its top-level commas (the
  /// {0,1} chain form has a comma of its own). Returns nil when brackets are unbalanced.
  private static func splitDescriptorArguments(_ text: Substring) -> [String]? {
    var arguments: [String] = []
    var current = ""
    var depth = 0

    for character in text {
      switch character {
      case "(", "[", "<", "{":
        depth += 1
        current.append(character)
      case ")", "]", ">", "}":
        depth -= 1
        guard depth >= 0 else { return nil }
        current.append(character)
      case "," where depth == 0:
        arguments.append(current)
        current = ""
      default:
        current.append(character)
      }
    }

    guard depth == 0 else { return nil }
    arguments.append(current)
    return arguments
  }

  /// Receive and change descriptors for imported descriptor text as it was
  /// written, without reading its keys.
  private static func splitImportedDescriptor(_ text: String) -> (external: String, change: String) {
    // Handle BIP-389 multipath descriptors: /<0;1>/* → split into /0/* and /1/*
    if text.contains("<0;1>/*") {
      return (
        text.replacingOccurrences(of: "<0;1>/*", with: "0/*"),
        text.replacingOccurrences(of: "<0;1>/*", with: "1/*")
      )
    }
    if text.contains("<1;0>/*") {
      return (
        text.replacingOccurrences(of: "<1;0>/*", with: "0/*"),
        text.replacingOccurrences(of: "<1;0>/*", with: "1/*")
      )
    }
    // Pre-BIP389 Specter DIY format: {0,1}/* → split into /0/* and /1/*
    if text.contains("{0,1}/*") {
      return (
        text.replacingOccurrences(of: "{0,1}/*", with: "0/*"),
        text.replacingOccurrences(of: "{0,1}/*", with: "1/*")
      )
    }
    if text.contains("{1,0}/*") {
      return (
        text.replacingOccurrences(of: "{1,0}/*", with: "0/*"),
        text.replacingOccurrences(of: "{1,0}/*", with: "1/*")
      )
    }
    // Standard single-path descriptor (external)
    if text.contains("/0/*") {
      return (text, text.replacingOccurrences(of: "/0/*", with: "/1/*"))
    }
    // Standard single-path descriptor (internal)
    if text.contains("/1/*") {
      return (text.replacingOccurrences(of: "/1/*", with: "/0/*"), text)
    }

    // No derivation suffix (e.g. Specter Desktop format) — append /0/* and /1/*
    // Replace each bare xpub (followed by , or )) with xpub/0/* for external
    let xpubPattern = #"([xt]pub[a-zA-Z0-9]+)(?=[,)])"#
    guard let xpubRegex = try? NSRegularExpression(pattern: xpubPattern) else {
      return (text, text)
    }
    let range = NSRange(location: 0, length: (text as NSString).length)
    return (
      xpubRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1/0/*"),
      xpubRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1/1/*")
    )
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
      guard buildDescriptors() else { return }
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

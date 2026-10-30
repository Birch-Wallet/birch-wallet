@testable import birch
import Foundation
import SwiftData
import Testing

/// Follows a wallet from the setup wizard, through saving, to the wallet the
/// app loads and hands out addresses from.
///
/// Expected addresses are Bitcoin Core's, from descriptor vectors #13 (receive)
/// and #14 (change), which are the same two keys.
@MainActor
struct WalletSetupFlowTests {
  // MARK: - Test Data Helpers

  private static let keys: [(xpub: String, fingerprint: String)] = [
    (xpub: "tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi",
     fingerprint: "effda333"),
    (xpub: "tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP",
     fingerprint: "0f056943"),
  ]

  private static func coreAddresses() throws -> (receive: [String], change: [String]) {
    let vectors = try DescriptorAddressVectorTests.loadVectors()
    let receive = try #require(vectors.first { $0.index == 13 }?.receiveRange)
    let change = try #require(vectors.first { $0.index == 14 }?.changeRange)
    return (receive, change)
  }

  /// One of the user's own servers, on a closed local port, so nothing leaves the
  /// machine. expectSavedWalletLoads inserts it, as the picker would have.
  private static func useUnreachableElectrumServer(_ vm: SetupWizardViewModel) {
    let server = ElectrumServer(name: "Closed port", host: "127.0.0.1", port: 1, useSSL: false, network: vm.network)
    vm.electrumServerChoice = .custom(server)
  }

  /// saveWallet marks the new wallet as the app's active one in UserDefaults.
  /// Put the host app's own values back as soon as it returns.
  private static func saveRestoringAppDefaults(_ vm: SetupWizardViewModel, context: ModelContext) throws {
    let defaults = UserDefaults.standard
    let keys = [Constants.activeWalletIDKey, Constants.hasCompletedOnboardingKey]
    let previous = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, previous) {
        defaults.set(value, forKey: key)
      }
    }
    try vm.saveWallet(modelContext: context)
  }

  /// Saves the wizard's wallet, loads it the way the app does, and checks the
  /// addresses it hands out against Bitcoin Core.
  private func expectSavedWalletLoads(
    _ vm: SetupWizardViewModel, core: (receive: [String], change: [String]),
  ) async throws {
    let schema = Schema([WalletProfile.self, CosignerInfo.self, ElectrumServer.self])
    let container = try ModelContainer(
      for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)],
    )
    let context = ModelContext(container)
    if case let .custom(server) = vm.electrumServerChoice {
      context.insert(server)
    }

    try Self.saveRestoringAppDefaults(vm, context: context)

    // What was saved is what the wizard showed
    let profiles = try context.fetch(FetchDescriptor<WalletProfile>())
    #expect(profiles.count == 1)
    let profile = try #require(profiles.first)
    #expect(profile.isActive)
    #expect(profile.requiredSignatures == 2)
    #expect(profile.totalCosigners == 2)
    #expect(profile.externalDescriptor == vm.externalDescriptor)
    #expect(profile.internalDescriptor == vm.internalDescriptor)

    // It syncs from the server the wizard showed, and a server of the user's own
    // becomes the one chosen last
    let choice = try #require(vm.electrumServerChoice)
    #expect(profile.electrumServerChoice == choice)
    if case let .custom(server) = choice {
      #expect(server.lastUsedAt != nil)
      #expect(server.wallets.map(\.id) == [profile.id])
    }

    let cosigners = profile.cosigners.sorted { $0.orderIndex < $1.orderIndex }
    #expect(cosigners.map(\.xpub) == vm.cosignerXpubs)
    #expect(cosigners.map(\.fingerprint) == vm.cosignerFingerprints)

    // Load it in a service of its own, not the one the host app is using
    let service = BitcoinService()
    defer {
      service.unloadWallet()
      try? FileManager.default.removeItem(at: Constants.walletDirectory(for: profile.id))
    }
    try await service.loadWallet(profile: profile)

    // Loading must not rewrite the saved descriptors
    #expect(profile.externalDescriptor == vm.externalDescriptor)
    #expect(profile.internalDescriptor == vm.internalDescriptor)

    // The Receive screen's address
    let receive0 = try #require(try service.getNextAddress())
    #expect(receive0.index == 0)
    #expect(receive0.address == core.receive[0])
    #expect(receive0.hasNext)

    // The address list: one gap-limit window on each chain, nothing used yet
    let receive = service.getAddresses(keychain: .external)
    let change = service.getAddresses(keychain: .internal)
    #expect(receive.count == profile.addressGapLimit)
    #expect(change.count == profile.addressGapLimit)
    #expect(receive.prefix(5).map(\.address) == core.receive)
    #expect(change.prefix(5).map(\.address) == core.change)
    #expect(receive.allSatisfy { !$0.isChange && !$0.isUsed })
    #expect(change.allSatisfy { $0.isChange && !$0.isUsed })
  }

  // MARK: - Tests

  @Test func `new wallet saves and loads to core addresses`() async throws {
    let core = try Self.coreAddresses()

    let vm = SetupWizardViewModel()
    vm.creationMode = .createNew
    vm.network = .testnet4
    vm.requiredSignatures = 2
    vm.totalCosigners = 2
    Self.useUnreachableElectrumServer(vm)

    vm.currentStep = .multisigConfig
    vm.goToNext()
    #expect(vm.currentStep == .cosignerImport)

    for (i, key) in Self.keys.enumerated() {
      vm.cosignerXpubs[i] = key.xpub
      vm.cosignerFingerprints[i] = key.fingerprint
    }
    // The wallet is named on Multisig configuration; Import cosigners goes
    // straight to Verify wallet
    vm.walletName = "Flow Test"
    vm.goToNext()
    #expect(vm.currentStep == .verify, "Descriptors were not built: \(vm.errorMessage ?? "")")
    #expect(vm.firstReceiveAddress == core.receive[0])

    try await expectSavedWalletLoads(vm, core: core)
  }

  @Test func `imported wallet saves and loads to core addresses`() async throws {
    let core = try Self.coreAddresses()

    let vm = SetupWizardViewModel()
    vm.creationMode = .importDescriptor
    vm.network = .testnet4
    // The network's public server, as setup shows it without one of the user's own
    vm.ensureElectrumServer(customServers: [])
    #expect(vm.electrumServerChoice?.id == "builtin:testnet4.mempool")
    vm.importedDescriptorText = "wsh(sortedmulti(2,"
      + Self.keys.map { "[\($0.fingerprint)/48h/1h/0h/2h]\($0.xpub)/<0;1>/*" }.joined(separator: ",")
      + "))"

    // The wallet is named on Import descriptor, and Import saves it
    vm.walletName = "Imported Flow Test"
    vm.currentStep = .descriptorImport
    let imported = vm.goToNext()
    #expect(imported, "Import failed: \(vm.importDescriptorError ?? "")")
    #expect(vm.currentStep == .descriptorImport)

    try await expectSavedWalletLoads(vm, core: core)
  }
}

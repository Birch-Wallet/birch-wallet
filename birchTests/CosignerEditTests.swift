@testable import birch
import Foundation
import SwiftData
import Testing

/// Editing cosigners rewrites an existing wallet's descriptors. A valid edit
/// must store exactly what the edited cosigners describe; an edit that cannot
/// be saved must leave the wallet as it was.
@MainActor
struct CosignerEditTests {
  // MARK: - Test Data Helpers

  private typealias Edit = (label: String, xpub: String, fingerprint: String, derivationPath: String)

  private static let path = "m/48'/1'/0'/2'"

  /// Valid testnet keys (B and C are from the Bitcoin Core address vectors)
  private static let keyA =
    "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ"
  private static let keyB =
    "tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP"
  private static let keyC =
    "tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi"

  /// A SLIP132 Vpub and the tpub it converts to (the same key)
  private static let vpub =
    "Vpub5kv6Y3xqGFyhZQyCz8LzaSwVzAJLJTvHcUewWAhrLRRRjZeYs53qrfspVEBKZw6rvwGy8Z1ef7e7Vzsu3BLF6MkjFXWnLpmftKQT1Eub5Cf"
  private static let vpubAsTpub =
    "tpubDE4AYPPuhwTk7ENvANSMNU84wRecxjikg4e1WFHE4a6fxsNogCqnA7zzxyDoXp93JeyWNViXEKnkqaysaCrZRnTZDLYXnmbt7zrGxWYc3Mx"

  private static let mainnetKey =
    "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz"

  /// An account-level key from a single-sig path, m/44'/1'/0' (descriptor vector #17):
  /// depth 3, last step 0'
  private static let accountLevelKey =
    "tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh"

  /// Key C with its depth field set to 0, as Birch used to rebuild a key scanned
  /// from a QR code that left the depth out
  private static let keyCWithDepth0 =
    "tpubD7uZy8aqfprHyVC1KErPPMtwqV5rzncNvDVBxvuwT6XChzVws9iSEVVwfYmxxYXajCvmAWs1EBmVGMzwtyk1gnEEr4q1tiQawE8kjBfLo8Q"

  private static let cosignerA: Edit = (label: "Cosigner 1", xpub: keyA, fingerprint: "73c5da0a", derivationPath: path)
  private static let cosignerB: Edit = (label: "Cosigner 2", xpub: keyB, fingerprint: "0f056943", derivationPath: path)
  private static let cosignerC: Edit = (label: "Coldcard", xpub: keyC, fingerprint: "effda333", derivationPath: path)

  private func createTestContainer() throws -> ModelContainer {
    let schema = Schema([WalletProfile.self, CosignerInfo.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private static func descriptor(_ cosigners: [Edit], isChange: Bool) throws -> String {
    try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners.map { (xpub: $0.xpub, fingerprint: $0.fingerprint, derivationPath: $0.derivationPath) },
      network: .testnet4,
      isChange: isChange
    )
  }

  /// A saved 2-of-2 testnet wallet, with cosigners A and B unless others are given.
  /// It is not the active wallet, so saving an edit does not reload the app's wallet.
  private func makeWallet(
    in context: ModelContext, cosigners: [Edit] = [CosignerEditTests.cosignerA, CosignerEditTests.cosignerB]
  ) throws -> WalletProfile {
    let wallet = try WalletProfile(
      name: "Edit Test",
      requiredSignatures: 2,
      totalCosigners: 2,
      externalDescriptor: Self.descriptor(cosigners, isChange: false),
      internalDescriptor: Self.descriptor(cosigners, isChange: true),
      network: .testnet4
    )
    context.insert(wallet)

    for (i, entry) in cosigners.enumerated() {
      let cosigner = CosignerInfo(
        label: entry.label, xpub: entry.xpub, fingerprint: entry.fingerprint,
        derivationPath: entry.derivationPath, orderIndex: i
      )
      cosigner.wallet = wallet
      context.insert(cosigner)
    }
    try context.save()
    return wallet
  }

  /// Everything an edit is allowed to change
  private func state(of wallet: WalletProfile) -> [String] {
    [wallet.externalDescriptor, wallet.internalDescriptor]
      + wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }.flatMap {
        [$0.label, $0.xpub, $0.fingerprint, $0.derivationPath]
      }
  }

  // MARK: - Valid edits

  @Test func validEditRebuildsDescriptorsAndRecords() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let walletManager = WalletManagerViewModel()

    // Replace the second cosigner
    let edited = [Self.cosignerA, Self.cosignerC]
    #expect(walletManager.updateCosigners(of: wallet, to: edited, modelContext: context))
    #expect(walletManager.errorMessage == nil)

    #expect(try wallet.externalDescriptor == Self.descriptor(edited, isChange: false))
    #expect(try wallet.internalDescriptor == Self.descriptor(edited, isChange: true))
    #expect(wallet.externalDescriptor.contains(Self.keyC))
    #expect(!wallet.externalDescriptor.contains(Self.keyB))
    #expect(wallet.requiredSignatures == 2)
    #expect(wallet.totalCosigners == 2)

    let saved = try context.fetch(FetchDescriptor<CosignerInfo>()).sorted { $0.orderIndex < $1.orderIndex }
    #expect(saved.map(\.label) == ["Cosigner 1", "Coldcard"])
    #expect(saved.map(\.xpub) == [Self.keyA, Self.keyC])
    #expect(saved.map(\.fingerprint) == ["73c5da0a", "effda333"])
  }

  @Test func editKeepsEnteredFormatWithoutSurroundingWhitespace() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let walletManager = WalletManagerViewModel()

    var second = Self.cosignerB
    second.xpub = "  \(Self.vpub)\n"
    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, second], modelContext: context))

    // The record keeps the Vpub as entered; the descriptor carries its tpub form
    let saved = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }
    #expect(saved[1].xpub == Self.vpub)
    #expect(wallet.externalDescriptor.contains(Self.vpubAsTpub))
    #expect(!wallet.externalDescriptor.contains("Vpub"))
  }

  // MARK: - Rejected edits

  @Test func rejectedEditLeavesWalletUntouched() throws {
    func second(_ change: (inout Edit) -> Void) -> [Edit] {
      var edit = Self.cosignerB
      change(&edit)
      return [Self.cosignerA, edit]
    }

    let rejected: [(name: String, edit: [Edit], message: String)] = [
      ("hidden second key", second { $0.xpub = "\(Self.keyB)/0/*,[aabbccdd/48'/1'/0'/2']\(Self.keyC)" }, "Cosigner 2"),
      ("bad checksum", second { $0.xpub = String(Self.keyB.dropLast()) + "R" }, "Cosigner 2"),
      ("truncated key", second { $0.xpub = String(Self.keyB.dropLast(10)) }, "Cosigner 2"),
      ("empty key", second { $0.xpub = "" }, "required"),
      ("mainnet key on a testnet wallet", second { $0.xpub = Self.mainnetKey }, "tpub"),
      ("key not at the BIP48 path", second { $0.xpub = Self.accountLevelKey }, "m/48'/1'/0'/2'"),
      ("same key as cosigner 1", second { $0.xpub = Self.keyA }, "same xpub"),
      ("short fingerprint", second { $0.fingerprint = "0f0569" }, "fingerprint"),
      ("non-hex fingerprint", second { $0.fingerprint = "0f05694z" }, "fingerprint"),
      ("mainnet derivation path", second { $0.derivationPath = "m/48'/0'/0'/2'" }, "mainnet"),
      ("account 1", second { $0.derivationPath = "m/48'/1'/1'/2'" }, "account 0"),
      ("one cosigner removed", [Self.cosignerA], "number of cosigners"),
      ("one cosigner added", [Self.cosignerA, Self.cosignerB, Self.cosignerC], "number of cosigners"),
    ]

    for (name, edit, message) in rejected {
      let container = try createTestContainer()
      let context = ModelContext(container)
      let wallet = try makeWallet(in: context)
      let before = state(of: wallet)
      let walletManager = WalletManagerViewModel()

      #expect(!walletManager.updateCosigners(of: wallet, to: edit, modelContext: context), "\(name) should be rejected")
      #expect(
        walletManager.errorMessage?.contains(message) == true,
        "\(name): unexpected message '\(walletManager.errorMessage ?? "nil")'"
      )
      #expect(state(of: wallet) == before, "\(name) changed the wallet")
    }
  }

  /// The same key entered once as a tpub and once as a Vpub is still one key.
  @Test func rejectDuplicateAcrossFormats() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let before = state(of: wallet)
    let walletManager = WalletManagerViewModel()

    var first = Self.cosignerA
    first.xpub = Self.vpubAsTpub
    var second = Self.cosignerB
    second.xpub = Self.vpub

    #expect(!walletManager.updateCosigners(of: wallet, to: [first, second], modelContext: context))
    #expect(walletManager.errorMessage?.contains("same xpub") == true)
    #expect(state(of: wallet) == before)
  }

  // MARK: - Keys already in the wallet

  /// Wallets saved before keys had to sit at the BIP48 path are not re-checked:
  /// a key already in the wallet does not block other edits. Bringing in another
  /// key that is off the path is still refused.
  @Test func keyAlreadyInWalletIsNotRecheckedForPlacement() throws {
    var legacy = Self.cosignerC
    legacy.xpub = Self.keyCWithDepth0

    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context, cosigners: [Self.cosignerA, legacy])
    let walletManager = WalletManagerViewModel()

    // Rename the cosigner whose key is off the path
    var renamed = legacy
    renamed.label = "Renamed"
    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, renamed], modelContext: context))
    #expect(wallet.cosigners.contains { $0.label == "Renamed" && $0.xpub == Self.keyCWithDepth0 })

    // Replace the other cosigner with a key at the path
    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerB, renamed], modelContext: context))
    #expect(try wallet.externalDescriptor == Self.descriptor([Self.cosignerB, renamed], isChange: false))

    // Swap the two slots: both keys are still the wallet's own
    #expect(walletManager.updateCosigners(of: wallet, to: [renamed, Self.cosignerB], modelContext: context))

    // A different key that is off the path is new to the wallet, so it is refused
    let before = state(of: wallet)
    var offPath = Self.cosignerB
    offPath.xpub = Self.accountLevelKey
    #expect(!walletManager.updateCosigners(of: wallet, to: [renamed, offPath], modelContext: context))
    #expect(walletManager.errorMessage?.contains("m/48'/1'/0'/2'") == true)
    #expect(state(of: wallet) == before)
  }

  // MARK: - Wallet database

  /// New descriptors need a fresh BDK database; a rejected edit must keep the
  /// one that matches the descriptors still in place.
  @Test func onlySavedEditClearsWalletDatabase() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let walletManager = WalletManagerViewModel()

    let directory = Constants.walletDirectory(for: wallet.id)
    let database = Constants.walletDatabasePath(for: wallet.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("stale".utf8).write(to: database)

    var invalid = Self.cosignerB
    invalid.xpub = "tpubA"
    #expect(!walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, invalid], modelContext: context))
    #expect(FileManager.default.fileExists(atPath: database.path))

    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerC], modelContext: context))
    #expect(!FileManager.default.fileExists(atPath: database.path))
  }
}

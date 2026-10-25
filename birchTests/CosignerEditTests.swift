@testable import birch
import BitcoinDevKit
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
    let schema = Schema([WalletProfile.self, CosignerInfo.self, WalletLabel.self, FrozenUTXO.self, SavedPSBT.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private static func descriptor(_ cosigners: [Edit], isChange: Bool) throws -> String {
    try BitcoinService.buildDescriptor(
      requiredSignatures: 2,
      cosigners: cosigners.map { (xpub: $0.xpub, fingerprint: $0.fingerprint, derivationPath: $0.derivationPath) },
      network: .testnet4,
      isChange: isChange,
    )
  }

  /// A saved 2-of-2 testnet wallet, with cosigners A and B unless others are given.
  /// It is not the active wallet, so saving an edit does not reload the app's wallet.
  private func makeWallet(
    in context: ModelContext, cosigners: [Edit] = [CosignerEditTests.cosignerA, CosignerEditTests.cosignerB],
  ) throws -> WalletProfile {
    let wallet = try WalletProfile(
      name: "Edit Test",
      requiredSignatures: 2,
      totalCosigners: 2,
      externalDescriptor: Self.descriptor(cosigners, isChange: false),
      internalDescriptor: Self.descriptor(cosigners, isChange: true),
      network: .testnet4,
    )
    context.insert(wallet)

    for (i, entry) in cosigners.enumerated() {
      let cosigner = CosignerInfo(
        label: entry.label, xpub: entry.xpub, fingerprint: entry.fingerprint,
        derivationPath: entry.derivationPath, orderIndex: i,
      )
      cosigner.wallet = wallet
      context.insert(cosigner)
    }
    try context.save()
    return wallet
  }

  /// The first `count` receive and change addresses the wallet's descriptors give,
  /// derived with BDK as the app does
  private func addresses(of wallet: WalletProfile, count: UInt32 = 10) throws -> [String] {
    let networkKind = BitcoinService.shared.bdkNetworkKind(from: wallet.bitcoinNetwork)
    let bdkWallet = try Wallet(
      descriptor: Descriptor(descriptor: wallet.externalDescriptor, networkKind: networkKind),
      changeDescriptor: Descriptor(descriptor: wallet.internalDescriptor, networkKind: networkKind),
      network: BitcoinService.shared.bdkNetwork(from: wallet.bitcoinNetwork),
      persister: Persister.newInMemory(),
    )
    return (0 ..< count).flatMap {
      [
        bdkWallet.peekAddress(keychain: .external, index: $0).address.description,
        bdkWallet.peekAddress(keychain: .internal, index: $0).address.description,
      ]
    }
  }

  /// A stand-in for the wallet's synced BDK database, removed by a key change
  private func writeDatabase(for wallet: WalletProfile) throws -> URL {
    let database = Constants.walletDatabasePath(for: wallet.id)
    try FileManager.default.createDirectory(at: Constants.walletDirectory(for: wallet.id), withIntermediateDirectories: true)
    try Data("synced".utf8).write(to: database)
    return database
  }

  /// What Save passes to `updateCosigners` from the Edit Cosigners form
  private func edits(from form: SetupWizardViewModel) -> [Edit] {
    (0 ..< form.totalCosigners).map {
      (
        label: form.cosignerLabels[$0], xpub: form.cosignerXpubs[$0],
        fingerprint: form.cosignerFingerprints[$0], derivationPath: form.cosignerDerivationPaths[$0],
      )
    }
  }

  /// Everything an edit is allowed to change
  private func state(of wallet: WalletProfile) -> [String] {
    [wallet.externalDescriptor, wallet.internalDescriptor]
      + wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }.flatMap {
        [$0.label, $0.xpub, $0.fingerprint, $0.derivationPath]
      }
  }

  // MARK: - Valid edits

  @Test func `valid edit rebuilds descriptors and records`() throws {
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

  @Test func `edit keeps entered format without surrounding whitespace`() throws {
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

  @Test func `rejected edit leaves wallet untouched`() throws {
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
        "\(name): unexpected message '\(walletManager.errorMessage ?? "nil")'",
      )
      #expect(state(of: wallet) == before, "\(name) changed the wallet")
    }
  }

  /// The same key entered once as a tpub and once as a Vpub is still one key.
  @Test func `reject duplicate across formats`() throws {
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
  @Test func `key already in wallet is not rechecked for placement`() throws {
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
  @Test func `only saved edit clears wallet database`() throws {
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

  // MARK: - Edits that leave the descriptors alone

  @Test func `cosigner change tells renames from key changes`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)

    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, Self.cosignerB]) == .none)

    var renamed = Self.cosignerB
    renamed.label = "Jade"
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, renamed]) == .detailsOnly)

    var padded = Self.cosignerB
    padded.xpub = "  \(Self.keyB)\n"
    var upperFingerprint = Self.cosignerB
    upperFingerprint.fingerprint = "0F056943"
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, padded]) == .none)
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, upperFingerprint]) == .none)

    var newFingerprint = Self.cosignerB
    newFingerprint.fingerprint = "aabbccdd"
    var newPath = Self.cosignerB
    newPath.derivationPath = "m/48'/1'/1'/2'"
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, Self.cosignerC]) == .keys)
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, newFingerprint]) == .keys)
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, newPath]) == .keys)
  }

  /// Renaming a cosigner, or writing its key as a Vpub, changes nothing the
  /// descriptors carry, so the wallet's data stays and nothing is refreshed.
  @Test func `renaming and reformatting keep descriptors and wallet database`() throws {
    var second = Self.cosignerB
    second.xpub = Self.vpubAsTpub

    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context, cosigners: [Self.cosignerA, second])
    let walletManager = WalletManagerViewModel()
    let descriptors = [wallet.externalDescriptor, wallet.internalDescriptor]

    let directory = Constants.walletDirectory(for: wallet.id)
    let database = Constants.walletDatabasePath(for: wallet.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("synced".utf8).write(to: database)

    var edited = second
    edited.label = "Jade"
    edited.xpub = Self.vpub
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, edited]) == .detailsOnly)
    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, edited], modelContext: context))

    let saved = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }
    #expect(saved[1].label == "Jade")
    #expect(saved[1].xpub == Self.vpub)
    #expect([wallet.externalDescriptor, wallet.internalDescriptor] == descriptors)
    #expect(FileManager.default.fileExists(atPath: database.path))
  }

  /// A rename still has to pass validation
  @Test func `rename with an invalid cosigner is rejected`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let before = state(of: wallet)
    let walletManager = WalletManagerViewModel()

    var renamed = Self.cosignerA
    renamed.label = "Renamed"
    var invalid = Self.cosignerB
    invalid.fingerprint = "0f0569"
    #expect(!walletManager.updateCosigners(of: wallet, to: [renamed, invalid], modelContext: context))
    #expect(state(of: wallet) == before)
  }

  // MARK: - Edit Cosigners form

  @Test func `editing form starts from the wallet's cosigners`() throws {
    var legacy = Self.cosignerC
    legacy.xpub = Self.keyCWithDepth0

    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context, cosigners: [Self.cosignerA, legacy])
    let form = SetupWizardViewModel.forEditing(wallet)

    #expect(form.network == .testnet4)
    #expect(form.requiredSignatures == 2)
    #expect(form.totalCosigners == 2)
    #expect(form.cosignerLabels == ["Cosigner 1", "Coldcard"])
    #expect(form.cosignerXpubs == [Self.keyA, Self.keyCWithDepth0])
    #expect(form.cosignerFingerprints == ["73c5da0a", "effda333"])
    #expect(form.cosignerDerivationPaths == [Self.path, Self.path])

    // The wallet's own off-path key passes, as it does in updateCosigners
    #expect(form.allCosignersComplete)

    // A key that is new to the wallet still has to sit at the BIP48 path
    form.cosignerXpubs[1] = Self.accountLevelKey
    #expect(!form.isCosignerComplete(1))
    #expect(form.cosignerProblems(at: 1)[.xpub]?.contains(Self.path) == true)
  }

  /// Save checks the cosigners the way Next does, without stepping the wizard
  @Test func `check cosigners flags problems and finishes in place`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let form = SetupWizardViewModel.forEditing(wallet)
    let step = form.currentStep

    form.cosignerXpubs[0] = "  \(Self.keyA)\n"
    #expect(form.checkCosigners() == .finish)
    #expect(form.cosignerXpubs[0] == Self.keyA)
    #expect(form.currentStep == step)

    form.cosignerFingerprints[0] = ""
    guard case let .flag(problems) = form.checkCosigners() else {
      Issue.record("An empty fingerprint should be flagged")
      return
    }
    #expect(problems[.fingerprint] != nil)
    #expect(form.cosignerErrors[0]?[.fingerprint] != nil)
    #expect(form.currentStep == step)
  }

  // MARK: - Funds stay where they were

  /// Renaming a cosigner or writing its key in another format must not move a
  /// single address: the coins stay exactly where the wallet sees them
  @Test func `renaming and reformatting keep every address`() throws {
    var second = Self.cosignerB
    second.xpub = Self.vpubAsTpub

    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context, cosigners: [Self.cosignerA, second])
    let before = try addresses(of: wallet)

    var edited = second
    edited.label = "Jade"
    edited.xpub = Self.vpub
    var renamedFirst = Self.cosignerA
    renamedFirst.label = "Coldcard"
    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: [renamedFirst, edited], modelContext: context))

    #expect(try addresses(of: wallet) == before)
  }

  /// Correcting a fingerprint rebuilds the descriptors (signers match keys by it),
  /// so it is a key change, but the addresses and so the funds stay the same
  @Test func `fingerprint change keeps addresses`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let before = try addresses(of: wallet)

    var corrected = Self.cosignerB
    corrected.fingerprint = "aabbccdd"
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, corrected]) == .keys)
    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: [Self.cosignerA, corrected], modelContext: context))

    #expect(wallet.externalDescriptor.contains("aabbccdd"))
    #expect(try addresses(of: wallet) == before)
  }

  /// Replacing a key really does give the wallet different addresses, which is
  /// why Save warns before it
  @Test func `replacing a key changes addresses`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let before = try addresses(of: wallet)

    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerC], modelContext: context))

    let after = try addresses(of: wallet)
    #expect(Set(after).isDisjoint(with: before))
  }

  /// A key change can be undone: entering the original keys again gives back the
  /// original descriptors and addresses, so the original funds reappear
  @Test func `restoring the original keys restores the original wallet`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let descriptors = [wallet.externalDescriptor, wallet.internalDescriptor]
    let before = try addresses(of: wallet)
    let walletManager = WalletManagerViewModel()

    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerC], modelContext: context))
    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerB], modelContext: context))

    #expect([wallet.externalDescriptor, wallet.internalDescriptor] == descriptors)
    #expect(try addresses(of: wallet) == before)
  }

  /// Saving with nothing changed must not clear the synced data or refresh
  @Test func `saving without changes touches nothing`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let before = state(of: wallet)
    let database = try writeDatabase(for: wallet)
    defer { try? FileManager.default.removeItem(at: Constants.walletDirectory(for: wallet.id)) }
    let walletManager = WalletManagerViewModel()

    #expect(walletManager.updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerB], modelContext: context))
    #expect(walletManager.errorMessage == nil)
    #expect(state(of: wallet) == before)
    #expect(FileManager.default.fileExists(atPath: database.path))
  }

  // MARK: - What a key change keeps

  /// Labels, frozen coins and saved PSBTs are keyed by the wallet, not its keys:
  /// a key change keeps them, so restoring the keys brings them back
  @Test func `key change keeps labels, frozen coins and saved PSBTs`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let txid = String(repeating: "ab", count: 32)
    context.insert(WalletLabel(walletID: wallet.id, type: .tx, ref: txid, label: "Rent"))
    context.insert(WalletLabel(walletID: wallet.id, type: .utxo, ref: "\(txid):0", label: "Savings"))
    context.insert(FrozenUTXO(walletID: wallet.id, txid: txid, vout: 0))
    context.insert(SavedPSBT(
      walletID: wallet.id, name: "Rent payment", psbtBytes: Data([0x70]), psbtBase64: "cA==",
      signaturesCollected: 1, requiredSignatures: 2, recipientsJSON: Data("[]".utf8), feeRateSatVb: "2",
      totalFee: 300, changeAmount: nil, changeAddress: nil, inputCount: 1, manualUTXOSelection: false,
      selectedUTXOIds: "", inputOutpoints: "\(txid):0",
    ))
    try context.save()

    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerC], modelContext: context))

    let walletID = wallet.id
    let labels = try context.fetch(FetchDescriptor<WalletLabel>(predicate: #Predicate { $0.walletID == walletID }))
    #expect(Set(labels.map(\.label)) == ["Rent", "Savings"])
    #expect(try context.fetch(FetchDescriptor<FrozenUTXO>(predicate: #Predicate { $0.walletID == walletID })).map(\.outpoint) == ["\(txid):0"])
    #expect(try context.fetch(FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.walletID == walletID })).map(\.name) == ["Rent payment"])
  }

  /// A key change rebuilds the descriptors and nothing else about the wallet
  @Test func `key change keeps the wallet's identity and settings`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    wallet.electrumHost = "electrum.example.com"
    wallet.blockExplorerHost = "mempool.example.com"
    wallet.addressGapLimit = 75
    wallet.privacyMode = true
    try context.save()
    let id = wallet.id
    let created = wallet.createdAt

    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: [Self.cosignerA, Self.cosignerC], modelContext: context))

    #expect(wallet.id == id)
    #expect(wallet.name == "Edit Test")
    #expect(wallet.createdAt == created)
    #expect(wallet.bitcoinNetwork == .testnet4)
    #expect(wallet.requiredSignatures == 2)
    #expect(wallet.totalCosigners == 2)
    #expect(wallet.electrumHost == "electrum.example.com")
    #expect(wallet.blockExplorerHost == "mempool.example.com")
    #expect(wallet.addressGapLimit == 75)
    #expect(wallet.privacyMode)
    #expect(wallet.cosigners.count == 2)
  }

  @Test func `editing one wallet leaves other wallets alone`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let edited = try makeWallet(in: context)
    let other = try makeWallet(in: context)
    let otherState = state(of: other)
    let otherAddresses = try addresses(of: other)
    let otherDatabase = try writeDatabase(for: other)
    defer {
      try? FileManager.default.removeItem(at: Constants.walletDirectory(for: edited.id))
      try? FileManager.default.removeItem(at: Constants.walletDirectory(for: other.id))
    }
    _ = try writeDatabase(for: edited)

    #expect(WalletManagerViewModel().updateCosigners(of: edited, to: [Self.cosignerA, Self.cosignerC], modelContext: context))

    #expect(!FileManager.default.fileExists(atPath: Constants.walletDatabasePath(for: edited.id).path))
    #expect(state(of: other) == otherState)
    #expect(try addresses(of: other) == otherAddresses)
    #expect(FileManager.default.fileExists(atPath: otherDatabase.path))
  }

  @Test func `a different number of cosigners counts as a key change`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)

    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA]) == .keys)
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: [Self.cosignerA, Self.cosignerB, Self.cosignerC]) == .keys)
  }

  // MARK: - The form and saving agree

  /// Opening Edit Cosigners and saving without touching anything must not warn
  /// about a key change or clear the wallet's data
  @Test func `untouched form reports no change`() throws {
    var second = Self.cosignerB
    second.xpub = Self.vpubAsTpub

    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context, cosigners: [Self.cosignerA, second])
    let form = SetupWizardViewModel.forEditing(wallet)

    #expect(form.checkCosigners() == .finish)
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: edits(from: form)) == .none)
  }

  /// The form shows the cosigners in the wallet's order, whatever order the
  /// records were saved in
  @Test func `form lists cosigners in wallet order`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    for cosigner in wallet.cosigners {
      cosigner.orderIndex = 1 - cosigner.orderIndex
    }
    try context.save()

    let form = SetupWizardViewModel.forEditing(wallet)
    #expect(form.cosignerLabels == ["Cosigner 2", "Cosigner 1"])
    #expect(form.cosignerXpubs == [Self.keyB, Self.keyA])
  }

  /// Save stays outlined and flags the cosigner for every edit that
  /// saving would refuse, so the form never offers a save that then fails
  @Test func `form flags every cosigner edit that saving rejects`() throws {
    let rejected: [(name: String, change: (inout Edit) -> Void)] = [
      ("empty key", { $0.xpub = "" }),
      ("hidden second key", { $0.xpub = "\(Self.keyB)/0/*,[aabbccdd/48'/1'/0'/2']\(Self.keyC)" }),
      ("bad checksum", { $0.xpub = String(Self.keyB.dropLast()) + "R" }),
      ("truncated key", { $0.xpub = String(Self.keyB.dropLast(10)) }),
      ("mainnet key on a testnet wallet", { $0.xpub = Self.mainnetKey }),
      ("new key not at the BIP48 path", { $0.xpub = Self.accountLevelKey }),
      ("same key as cosigner 1", { $0.xpub = Self.keyA }),
      ("short fingerprint", { $0.fingerprint = "0f0569" }),
      ("non-hex fingerprint", { $0.fingerprint = "0f05694z" }),
      ("mainnet derivation path", { $0.derivationPath = "m/48'/0'/0'/2'" }),
      ("account 1", { $0.derivationPath = "m/48'/1'/1'/2'" }),
    ]

    for (name, change) in rejected {
      let container = try createTestContainer()
      let context = ModelContext(container)
      let wallet = try makeWallet(in: context)
      let form = SetupWizardViewModel.forEditing(wallet)
      var second = Self.cosignerB
      change(&second)
      form.cosignerXpubs[1] = second.xpub
      form.cosignerFingerprints[1] = second.fingerprint
      form.cosignerDerivationPaths[1] = second.derivationPath

      #expect(!form.allCosignersComplete, "\(name): Save should stay outlined")
      #expect(form.checkCosigners() != .finish, "\(name): Save should flag instead of saving")
      #expect(
        !WalletManagerViewModel().updateCosigners(of: wallet, to: edits(from: form), modelContext: context),
        "\(name): saving should refuse it too",
      )
    }
  }

  /// The same key written as a tpub in one slot and a Vpub in another is a
  /// duplicate in the form, as it is when saving
  @Test func `form flags the same key in another format`() throws {
    var first = Self.cosignerA
    first.xpub = Self.vpubAsTpub

    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context, cosigners: [first, Self.cosignerB])
    let form = SetupWizardViewModel.forEditing(wallet)
    form.cosignerXpubs[1] = Self.vpub

    #expect(form.cosignerProblems(at: 1)[.xpub]?.contains("Duplicate") == true)
    #expect(!form.allCosignersComplete)
  }

  /// Every edit the form lets through, saving accepts
  @Test func `form accepts what saving accepts`() throws {
    var legacy = Self.cosignerC
    legacy.xpub = Self.keyCWithDepth0

    let accepted: [(name: String, cosigners: [Edit], change: (SetupWizardViewModel) -> Void)] = [
      ("rename", [Self.cosignerA, Self.cosignerB], { $0.cosignerLabels[1] = "Jade" }),
      ("replace a key", [Self.cosignerA, Self.cosignerB], {
        $0.cosignerXpubs[1] = Self.keyC
        $0.cosignerFingerprints[1] = "effda333"
      }),
      ("enter a Vpub", [Self.cosignerA, Self.cosignerB], { $0.cosignerXpubs[1] = Self.vpub }),
      ("key with surrounding whitespace", [Self.cosignerA, Self.cosignerB], { $0.cosignerXpubs[1] = "  \(Self.keyC)\n" }),
      ("rename beside an older off-path key", [Self.cosignerA, legacy], { $0.cosignerLabels[0] = "Renamed" }),
    ]

    for (name, cosigners, change) in accepted {
      let container = try createTestContainer()
      let context = ModelContext(container)
      let wallet = try makeWallet(in: context, cosigners: cosigners)
      let form = SetupWizardViewModel.forEditing(wallet)
      change(form)

      #expect(form.checkCosigners() == .finish, "\(name): the form should let Save through")
      let walletManager = WalletManagerViewModel()
      #expect(
        walletManager.updateCosigners(of: wallet, to: edits(from: form), modelContext: context),
        "\(name): saving refused it: \(walletManager.errorMessage ?? "")",
      )
    }
  }

  /// Fixing a flagged field clears its flag and lets Save through
  @Test func `fixing a flagged cosigner lets save through`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let form = SetupWizardViewModel.forEditing(wallet)

    form.cosignerXpubs[1] = ""
    form.openCosigner(1)
    #expect(form.checkCosigners() != .finish)
    #expect(form.cosignerErrors[1]?[.xpub] != nil)

    let old = form.cosignerXpubs
    form.cosignerXpubs[1] = Self.keyC
    form.clearErrors(.xpub, editedFrom: old, to: form.cosignerXpubs)
    #expect(form.cosignerErrors[1] == nil)
    form.cosignerFingerprints[1] = "effda333"
    #expect(form.checkCosigners() == .finish)
  }

  /// The format button in Edit Cosigners: switching a key to its Vpub and back
  /// is the same key, so it saves without a rebuild or refresh and keeps every
  /// address
  @Test func `format toggle in the edit form keeps the wallet`() throws {
    let container = try createTestContainer()
    let context = ModelContext(container)
    let wallet = try makeWallet(in: context)
    let descriptors = [wallet.externalDescriptor, wallet.internalDescriptor]
    let before = try addresses(of: wallet)
    let database = try writeDatabase(for: wallet)
    defer { try? FileManager.default.removeItem(at: Constants.walletDirectory(for: wallet.id)) }

    let form = SetupWizardViewModel.forEditing(wallet)
    form.cosignerXpubs[1] = try #require(URService.toggleXpubFormat(form.cosignerXpubs[1], isTestnet: true))
    #expect(form.cosignerXpubs[1].hasPrefix("Vpub"))
    #expect(form.checkCosigners() == .finish)
    #expect(WalletManagerViewModel.cosignerChange(of: wallet, to: edits(from: form)) == .detailsOnly)
    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: edits(from: form), modelContext: context))

    let saved = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }
    #expect(saved[1].xpub.hasPrefix("Vpub"))
    #expect([wallet.externalDescriptor, wallet.internalDescriptor] == descriptors)
    #expect(try addresses(of: wallet) == before)
    #expect(FileManager.default.fileExists(atPath: database.path))

    // And back to the tpub
    let again = SetupWizardViewModel.forEditing(wallet)
    again.cosignerXpubs[1] = try #require(URService.toggleXpubFormat(again.cosignerXpubs[1], isTestnet: true))
    #expect(again.cosignerXpubs[1] == Self.keyB)
    #expect(WalletManagerViewModel().updateCosigners(of: wallet, to: edits(from: again), modelContext: context))
    #expect(wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }[1].xpub == Self.keyB)
    #expect([wallet.externalDescriptor, wallet.internalDescriptor] == descriptors)
  }
}

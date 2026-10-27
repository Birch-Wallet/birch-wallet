import BitcoinDevKit
import Combine
import Foundation
import Network
import SwiftData

// MARK: - Fee Source

enum FeeSource: String, CaseIterable {
  case mempoolSpace = "mempool"
  case electrum
  case fixed

  var displayName: String {
    switch self {
    case .mempoolSpace: "mempool.space"
    case .electrum: "Electrum Server"
    case .fixed: "Fixed Default"
    }
  }
}

private let logger = AppLog(.sync)
private let psbtLogger = AppLog(.psbt)

@Observable
@MainActor
final class BitcoinService {
  static let shared = BitcoinService()

  private(set) var wallet: Wallet?
  private var persister: Persister?
  private var electrumClient: ElectrumClient?
  private(set) var currentProfile: WalletProfile?
  var modelContainer: ModelContainer?

  var currentNetwork: BitcoinNetwork? {
    currentProfile?.bitcoinNetwork
  }

  private(set) var balance: UInt64 = 0
  private(set) var transactions: [TransactionItem] = []
  private(set) var utxos: [UTXOItem] = []
  /// Every output this wallet has received, spent or not. `utxos` is the unspent subset.
  private(set) var outputs: [UTXOItem] = []
  private(set) var requiredSignatures: Int = 2
  private(set) var totalCosigners: Int = 1
  private(set) var chainTipHeight: UInt32 = 0
  var syncTask: Task<Void, Error>?

  // Sync state — single source of truth
  private(set) var syncState: WalletSyncState = .notStarted
  private(set) var lastSyncDate: Date?
  private(set) var syncLog: [String] = []

  /// How far the running sync has got, for the hairline under the balance: nil while
  /// there is no total to measure it against (a wallet's first sync, so the bar
  /// sweeps), and 1 once it finished
  private(set) var syncProgress: Double?
  @ObservationIgnored private var progressTracker: SyncProgressTracker?
  @ObservationIgnored private var progressTicker: Task<Void, Never>?
  /// What the running sync is doing now, for the connection sheet's Action row; nil
  /// when no sync is running
  private(set) var syncAction: SyncAction?
  @ObservationIgnored private var syncStartUptime: TimeInterval = 0
  /// The batches the saved wallet predicted when the sync started, nil on a first sync
  @ObservationIgnored private var plannedBatchCounts: SyncWorkPlan.BatchCounts?
  /// How many batches the running scan has started
  @ObservationIgnored private var scanBatchNumber = 0

  /// Incremented whenever the wallet instance is replaced (load, reload, or unload).
  /// Comparing generations lets an in-flight sync detect that its wallet was swapped
  /// out even when the profile id is unchanged — e.g. a descriptor edit reloads the
  /// same profile with a fresh Wallet and persister.
  private var walletGeneration: UInt64 = 0

  /// Updates syncState only if the wallet the sync started against is still loaded.
  /// Prevents a long-running sync from overwriting UI state after a wallet switch
  /// or same-profile reload.
  private func setSyncState(_ state: WalletSyncState, generation: UInt64) {
    guard walletGeneration == generation else { return }
    syncState = state
  }

  private static let syncLogTimestampFormatter = ISO8601DateFormatter()

  private func addToLog(_ message: String) {
    let timestamp = Self.syncLogTimestampFormatter.string(from: Date())
    let entry = "[\(timestamp)] \(message)"
    logger.info(message)
    syncLog.append(entry)
    if syncLog.count > 100 {
      syncLog.removeFirst()
    }
  }

  var timeSinceLastSync: TimeInterval {
    guard let lastSyncDate else { return .infinity }
    return Date().timeIntervalSince(lastSyncDate)
  }

  // MARK: - Auto Sync

  private var autoSyncCancellable: AnyCancellable?

  func startAutoSync() {
    guard autoSyncCancellable == nil else { return }
    autoSyncCancellable = Timer.publish(every: Constants.autoSyncInterval, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        guard let self, !self.syncState.isSyncing, wallet != nil else { return }
        syncTask = Task {
          try? await self.sync(fullResync: false, trigger: .automatic)
        }
      }
  }

  func stopAutoSync() {
    autoSyncCancellable?.cancel()
    autoSyncCancellable = nil
  }

  func restartAutoSync() {
    stopAutoSync()
    startAutoSync()
  }

  /// Check if enough time has passed since last sync and sync if needed
  func autoSyncIfNeeded() {
    guard !syncState.isSyncing, wallet != nil else { return }
    if timeSinceLastSync >= Constants.autoSyncInterval {
      syncTask = Task {
        try? await self.sync(fullResync: false, trigger: .automatic)
      }
    }
  }

  // MARK: - Network

  /// NetworkMonitor's changes. Only going offline and coming back act: a change
  /// between Wi-Fi and cellular, Wi-Fi Assist or a VPN leaves the connection and any
  /// sync alone. A sync that loses the network ends at its timeouts.
  func networkChanged(from old: NetworkState, to new: NetworkState) {
    addToLog("Network: \(new.logDescription)")
    if new.isOffline, !old.isOffline {
      electrumVerified = false
      electrumConnectionError = new.message
    }
    guard NetworkState.cameBackOnline(from: old, to: new) else { return }
    Task {
      try? await Task.sleep(for: .seconds(Constants.backOnlineSettleSeconds))
      resumeAfterOffline()
    }
  }

  /// Back online: syncs if a sync was missed while offline, the last one failed or one
  /// is due, and otherwise checks the connection so its status is current again
  private func resumeAfterOffline() {
    guard !NetworkMonitor.shared.state.isOffline, wallet != nil, !syncState.isSyncing else { return }
    let reason: String? = if syncPendingOnline {
      "a sync was missed while offline"
    } else if syncState.errorMessage != nil {
      "the last sync failed"
    } else if timeSinceLastSync >= Constants.autoSyncInterval {
      "a sync is due"
    } else {
      nil
    }
    syncPendingOnline = false
    if let reason {
      addToLog("Back online: syncing, because \(reason)")
      syncTask = Task {
        try? await self.sync(fullResync: false, trigger: .automatic)
      }
    } else if !isElectrumConnected {
      addToLog("Back online: checking the connection")
      Task {
        await checkConnection()
      }
    }
  }

  /// True only after we have successfully fetched data from the Electrum server.
  private(set) var electrumVerified = false

  var isElectrumConnected: Bool {
    electrumClient != nil && electrumVerified
  }

  /// Stores the last Electrum connection error for display in the UI.
  private(set) var electrumConnectionError: String?

  /// A sync didn't start because the phone was offline, so one runs when it's back
  @ObservationIgnored private var syncPendingOnline = false

  var electrumURL: String? {
    guard let profile = currentProfile else { return nil }
    return profile.electrumConfig.url
  }

  /// The server to connect `profile` to: its own, unless the screenshot tour
  /// names a local one for a wallet left on the network's default
  /// (ScreenshotFixtures.electrumServer)
  private func connectionConfig(for profile: WalletProfile) -> ElectrumConfig {
    #if DEBUG
      if ScreenshotFixtures.isActive, profile.electrumHost.isEmpty,
         let server = ScreenshotFixtures.electrumServer(for: profile.bitcoinNetwork)
      {
        return server
      }
    #endif
    return profile.electrumConfig
  }

  /// Returns a user-friendly description for Electrum connection errors,
  /// detecting self-signed certificate issues that BDK cannot handle.
  static func friendlyElectrumError(_ error: Error) -> String {
    // Birch's own connection errors already say what happened
    if case let AppError.electrumConnectionFailed(detail) = error {
      return detail
    }
    let msg = "\(error)"
    if msg.contains("InvalidCertificate") || msg.contains("CertificateRequired")
      || msg.contains("BadCertificate") || msg.contains("UnknownIssuer")
    {
      return "SSL certificate rejected — the server may use a self-signed certificate which BDK does not support. Try using TCP instead of SSL, or use a server with a CA-signed certificate."
    }
    if msg.contains("AllAttemptsErrored") || msg.contains("CouldNotCreateConnection") {
      return "Could not connect to Electrum server — check your network connection and server settings."
    }
    return msg
  }

  /// A new connection to an Electrum server. The TCP connect and every read and write
  /// give up after `Constants.electrumTimeoutSeconds`, and a failed call reconnects and
  /// tries once more.
  nonisolated static func makeElectrumClient(url: String, validateDomain: Bool) throws -> ElectrumClient {
    try ElectrumClient(
      url: url,
      timeout: Constants.electrumTimeoutSeconds,
      retry: Constants.electrumRetries,
      validateDomain: validateDomain,
    )
  }

  /// The arguments `makeElectrumClient` passes, for the Action row and the log
  private static func clientCall(_ config: ElectrumConfig) -> String {
    "ElectrumClient(url: \(config.url), timeout: \(Constants.electrumTimeoutSeconds), "
      + "retry: \(Constants.electrumRetries), validateDomain: \(!config.allowInsecureSSL))"
  }

  /// Runs a blocking Electrum call while connecting to `config`'s server, which has
  /// until `deadline` (system uptime). Past it, it throws the error the UI shows.
  private nonisolated static func connecting<T>(
    to config: ElectrumConfig,
    until deadline: TimeInterval,
    _ work: @escaping @Sendable () throws -> T,
  ) async throws -> T {
    do {
      return try await BlockingCall.run(until: deadline, work)
    } catch is BlockingCall.DeadlineExceeded {
      throw connectTimedOut(host: config.host, port: config.port)
    }
  }

  /// What a sync, check, test or fee estimate says when connecting runs out of time
  private nonisolated static func connectTimedOut(host: String, port: UInt16) -> AppError {
    .electrumConnectionFailed("Couldn't reach \(host):\(port) within \(Int(Constants.electrumConnectSeconds)) seconds")
  }

  /// Opens a new connection to `config`'s server, giving up at `deadline`
  private nonisolated static func openConnection(to config: ElectrumConfig, until deadline: TimeInterval) async throws -> ElectrumClient {
    let url = config.url
    let validateDomain = !config.allowInsecureSSL
    return try await connecting(to: config, until: deadline) {
      try makeElectrumClient(url: url, validateDomain: validateDomain)
    }
  }

  /// Not private, so a test can load a wallet into a service of its own instead
  /// of the one the running app is using. App code goes through `shared`.
  init() {}

  // MARK: - Wallet Lifecycle

  func unloadWallet() {
    walletGeneration += 1
    syncTask?.cancel()
    syncTask = nil
    stopAutoSync()
    wallet = nil
    persister = nil
    electrumClient = nil
    electrumVerified = false
    electrumConnectionError = nil
    chainTipHeight = 0
    currentProfile = nil
    balance = 0
    transactions = []
    utxos = []
    outputs = []
    syncState = .notStarted
    resetSyncProgress()
    lastSyncDate = nil
    syncLog = []
  }

  private func resetSyncProgress() {
    progressTicker?.cancel()
    progressTicker = nil
    progressTracker = nil
    syncProgress = nil
    syncAction = nil
  }

  func loadWallet(profile: WalletProfile) async throws {
    // Always cancel any in-flight sync — it runs against a wallet instance we are
    // about to replace, even when reloading the same profile (descriptor edits).
    syncTask?.cancel()
    syncTask = nil

    // Clear previous wallet state when switching profiles
    if currentProfile != nil, currentProfile?.id != profile.id {
      addToLog("Switching wallets — unloading previous wallet")
      unloadWallet()
    }

    let network = bdkNetwork(from: profile.bitcoinNetwork)
    addToLog("Loading wallet for profile: \(profile.name) (\(profile.id)) on \(profile.bitcoinNetwork.displayName)")

    // Auto-repair malformed descriptors
    var extDescStr = profile.externalDescriptor
    var intDescStr = profile.internalDescriptor

    // Normalize smart/curly quotes to ASCII apostrophes (iOS keyboard substitution)
    for smartQuote in ["\u{2018}", "\u{2019}", "\u{02BC}"] {
      extDescStr = extDescStr.replacingOccurrences(of: smartQuote, with: "'")
      intDescStr = intDescStr.replacingOccurrences(of: smartQuote, with: "'")
    }

    // Fix double slashes from trailing-slash xpubs
    extDescStr = extDescStr.replacingOccurrences(of: "//", with: "/")
    intDescStr = intDescStr.replacingOccurrences(of: "//", with: "/")

    // Auto-repair BIP-389 multipath notation — BDK requires separate /0/* and /1/* descriptors
    if extDescStr.contains("<0;1>/*") {
      addToLog("Auto-repairing multipath descriptor: splitting <0;1>/* into /0/* and /1/*")
      extDescStr = extDescStr.replacingOccurrences(of: "<0;1>/*", with: "0/*")
      intDescStr = intDescStr.replacingOccurrences(of: "<0;1>/*", with: "1/*")
    }

    if extDescStr != profile.externalDescriptor || intDescStr != profile.internalDescriptor {
      addToLog("Descriptors auto-repaired — updating profile and clearing stale database")
      profile.externalDescriptor = extDescStr
      profile.internalDescriptor = intDescStr
      // Descriptor changed — delete stale BDK database so wallet is recreated
      let staleDbPath = Constants.walletDatabasePath(for: profile.id)
      try? FileManager.default.removeItem(at: staleDbPath)
    }

    let walletDir = Constants.walletDirectory(for: profile.id)
    addToLog("Creating wallet directory: \(walletDir.path)")
    try FileManager.default.createDirectory(at: walletDir, withIntermediateDirectories: true)

    let dbPath = Constants.walletDatabasePath(for: profile.id)
    addToLog("Opening database: \(dbPath.path)")
    let persister = try Persister.newSqlite(path: dbPath.path)

    addToLog("Parsing external descriptor (\(extDescStr.count) chars): \(extDescStr)")
    let descriptorNetworkKind = bdkNetworkKind(from: profile.bitcoinNetwork)
    let externalDesc = try Descriptor(descriptor: extDescStr, networkKind: descriptorNetworkKind)
    addToLog("Parsing internal/change descriptor")
    let changeDesc = try Descriptor(descriptor: intDescStr, networkKind: descriptorNetworkKind)

    // Try loading existing wallet first, create new if not found
    let w: Wallet
    do {
      addToLog("Attempting to load existing wallet from database")
      w = try Wallet.load(descriptor: externalDesc, changeDescriptor: changeDesc, persister: persister)
      addToLog("Existing wallet loaded from database")
    } catch {
      // No persisted wallet — create fresh
      addToLog("No existing wallet found (\(error)), creating new wallet instance")
      w = try Wallet(
        descriptor: externalDesc,
        changeDescriptor: changeDesc,
        network: network,
        persister: persister,
      )
      // Reveal address #0 on both keychains, so a new wallet starts with its first
      // receive and change addresses on record.
      _ = w.revealNextAddress(keychain: .external)
      _ = w.revealNextAddress(keychain: .internal)
      _ = try w.persist(persister: persister)
      addToLog("Revealed address #0 for external and internal keychains")
    }

    syncState = .notStarted
    resetSyncProgress()
    // The last sync outlives a relaunch or a switch to another wallet, so the header
    // can say when it was and opening the wallet can skip a sync it doesn't need. A
    // database that has never synced (new, or rebuilt) has no last sync to go by.
    let lastSyncKey = Self.lastSyncKey(profile.id)
    if w.latestCheckpoint().height > 0, let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
      lastSyncDate = lastSync
      syncState = .synced(lastSync)
    } else {
      lastSyncDate = nil
      UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }

    walletGeneration += 1
    wallet = w
    self.persister = persister
    currentProfile = profile
    requiredSignatures = profile.requiredSignatures
    totalCosigners = profile.totalCosigners

    // Restore last-known chain tip so cached confirmations are reasonable (not 1)
    chainTipHeight = UInt32(UserDefaults.standard.integer(forKey: "chainTipHeight_\(profile.id.uuidString)"))

    // Load cached data from persisted wallet first (works offline)
    updateCachedData()

    // Loading doesn't connect, so the saved wallet shows at once even when the server
    // can't be reached. The sync or check that opening the wallet starts connects,
    // with the bar and the connect limit. A reload may have changed the server.
    electrumClient = nil
    electrumVerified = false
    electrumConnectionError = nil
  }

  // MARK: - Sync

  /// Who asked for a sync. While the phone is offline, one the user asked for throws,
  /// so the screen that asked can say so; an automatic one returns quietly.
  private enum SyncTrigger {
    case user
    case automatic
  }

  func sync() async throws {
    try await sync(fullResync: false, trigger: .user)
  }

  /// Full Resync: syncs over a new connection without filling its cache from the saved
  /// wallet, so every transaction comes from the server again, as if populateTxCache
  /// didn't exist. The saved wallet stays, and the scan merges into it as any sync does.
  func fullResync() async throws {
    try await sync(fullResync: true, trigger: .user)
  }

  private func sync(fullResync: Bool, trigger: SyncTrigger) async throws {
    guard let wallet else {
      addToLog("Sync failed: Wallet not loaded")
      throw AppError.walletNotLoaded
    }

    guard !syncState.isSyncing else {
      addToLog("Sync skipped: already in progress")
      return
    }

    // Offline, nothing can connect, so the sync doesn't start and the bar doesn't
    // move. It runs once the network is back.
    let network = NetworkMonitor.shared.state
    if network.isOffline {
      syncPendingOnline = true
      electrumVerified = false
      electrumConnectionError = network.message
      addToLog("Sync not started: \(network.logDescription)")
      guard trigger == .user else { return }
      throw AppError.electrumConnectionFailed(network.message)
    }

    // Capture wallet identity and persister at start — if the wallet is switched
    // or reloaded during sync, we must not apply results or persist to the wrong
    // database. The generation (not the profile id) is the identity check, so a
    // same-profile reload also invalidates this sync.
    let syncGeneration = walletGeneration
    let syncProfileId = currentProfile?.id // for per-profile UserDefaults keys only
    let syncPersister = persister
    let gapLimit = currentProfile?.scanGapLimit ?? Constants.defaultAddressGap

    // The work this sync should take, from what the saved wallet holds. A wallet
    // that has never synced has nothing to go on, so its bar sweeps instead. One that
    // has fills a new connection's cache from its saved transactions before the scan
    // (populateTxCache), so the connection is about as warm as one that already synced
    // it: only the merkle proofs, fetched in batches, come again. Full Resync doesn't,
    // so it downloads everything.
    let walletHasSynced = wallet.latestCheckpoint().height != 0
    let clientWarm = walletHasSynced && !fullResync
    let plan = walletHasSynced ? syncWorkPlan(for: wallet, gap: gapLimit, clientWarm: clientWarm) : nil
    let learnedSecondsPerUnit = syncProfileId.map { UserDefaults.standard.double(forKey: Self.syncPaceKey($0)) } ?? 0
    startProgress(plan: plan, secondsPerUnit: learnedSecondsPerUnit, generation: syncGeneration)
    syncStartUptime = Self.uptime
    plannedBatchCounts = plan?.batchCounts
    scanBatchNumber = 0
    syncAction = nil
    defer {
      if walletGeneration == syncGeneration {
        progressTicker?.cancel()
      }
    }

    setSyncState(.syncing(.connecting), generation: syncGeneration)
    addToLog(
      (fullResync ? "Starting full resync (gap \(gapLimit), " : "Starting sync (gap \(gapLimit), ")
        + (plan.map { "expecting \(Int($0.totalUnits)) round trips in \($0.batches.count) batches" } ?? "first sync, no estimate")
        + (clientWarm ? ", client cache warm)" : ")"),
    )

    // Capture pre-sync state so completion can log deltas.
    let syncStartTime = Date()
    let balanceBefore = balance
    let txCountBefore = transactions.count
    let utxoCountBefore = utxos.count

    do {
      guard let profile = currentProfile else { throw AppError.walletNotLoaded }

      // Every sync opens a new connection. One left open since the last sync may have
      // died while idle without either side hearing of it, as when a carrier drops an
      // idle connection, and its first request would wait out the socket timeout.
      // Connecting, the ping and the chain tip share one limit, so a server that can't
      // be reached fails the sync instead of holding the bar under 20%.
      let config = connectionConfig(for: profile)
      let connectDeadline = Self.uptime + Constants.electrumConnectSeconds
      beginSyncAction(
        "Connecting to \(config.host):\(config.port) (\(config.useSSL ? "TCP and TLS handshake" : "TCP, no TLS"))",
        calls: Self.clientCall(config),
        generation: syncGeneration,
      )
      let client = try await Self.openConnection(to: config, until: connectDeadline)
      guard walletGeneration == syncGeneration else {
        addToLog("Sync cancelled: wallet replaced while connecting")
        return
      }
      electrumClient = client
      electrumConnectionError = nil

      // A new connection's cache is empty, so the scan would download every saved
      // transaction again, one round trip each. Filling it from the saved wallet costs
      // no round trips. The merkle proofs still come from the server, in batches, and
      // are checked against its headers. Full Resync leaves it empty.
      if walletHasSynced, !fullResync {
        beginSyncAction(
          "Filling the connection's cache with the saved transactions",
          calls: "ElectrumClient.populateTxCache (no network)",
          generation: syncGeneration,
        )
        let populateStart = Self.uptime
        client.populateTxCache(txs: wallet.transactions().map(\.transaction))
        addToLog("Cache filled from the saved wallet in \(Self.milliseconds(Self.uptime - populateStart))")
      }

      // Verify the server is reachable before the scan starts, so the bar doesn't
      // show progress while offline or while the server is down.
      beginSyncAction("Checking that the server answers", calls: "server.ping", generation: syncGeneration)
      let pingStart = Self.uptime
      try await Self.connecting(to: config, until: connectDeadline) { try client.ping() }
      let pingSeconds = Self.uptime - pingStart
      addToLog("Server ping OK (\(Self.milliseconds(pingSeconds)))")

      // Fetch chain tip early to confirm server returns real data
      beginSyncAction("Fetching the server's chain tip", calls: "blockchain.headers.subscribe", generation: syncGeneration)
      guard try await updateChainTip(
        from: client, config: config, until: connectDeadline, generation: syncGeneration, profileId: syncProfileId,
      ) else {
        addToLog("Sync cancelled: wallet replaced during chain tip fetch")
        return
      }

      // Without a measured pace yet, a round trip is about one ping
      if learnedSecondsPerUnit <= 0 {
        progressTracker?.secondsPerUnit = Self.clampedSecondsPerUnit(pingSeconds)
      }
      progressTracker?.serverReady(now: Self.uptime)
      publishProgress()
      setSyncState(.syncing(.fetching), generation: syncGeneration)

      // Every sync is a full scan: it walks both keychains until `gapLimit` unused
      // addresses in a row, so it finds funds on any address, revealed or not.
      let inspector = FullScanProgressInspector(batchSize: Constants.syncBatchSize) { [weak self] keychain, index, time in
        MainActor.assumeIsolated {
          self?.syncBatchStarted(keychain: keychain, index: index, at: time, generation: syncGeneration)
        }
      }
      let fullScanRequest = try wallet.startFullScan()
        .inspectSpksForAllKeychains(inspector: inspector)
        .build()

      beginSyncAction(
        "Starting the full scan: fetching the server's latest blocks",
        calls: "BDK full_scan (gap \(gapLimit), batch \(Constants.syncBatchSize), fetchPrevTxouts off): "
          + "blockchain.headers.subscribe, then blockchain.block.header for the latest blocks (batched)",
        generation: syncGeneration,
      )
      let scanStart = Self.uptime
      // fetchPrevTxouts would download the parent of every received payment on every
      // sync, though the wallet keeps the outputs it needs from them. The ones it's
      // missing are downloaded after the scan instead (downloadMissingPrevouts).
      let update = try await Task.detached { [client] in
        try client.fullScan(
          request: fullScanRequest,
          stopGap: UInt64(gapLimit),
          batchSize: UInt64(Constants.syncBatchSize),
          fetchPrevTxouts: false,
        )
      }.value
      let scanSeconds = Self.uptime - scanStart

      // Bail out if the wallet was switched or reloaded during the network scan
      guard walletGeneration == syncGeneration else {
        addToLog("Sync cancelled: wallet replaced during full scan")
        return
      }
      try Task.checkCancellation()

      addToLog("Full scan returned in \(String(format: "%.1f", scanSeconds))s, bar at \(Self.percent(progressTracker?.fraction))")
      beginSyncAction("Applying the scan's update to the wallet", calls: "BDK Wallet.applyUpdate", generation: syncGeneration)
      try wallet.applyUpdate(update: update)
      await downloadMissingPrevouts(client: client, wallet: wallet, generation: syncGeneration)

      // Final identity check before persisting
      guard walletGeneration == syncGeneration else {
        addToLog("Sync cancelled: wallet replaced before persist")
        return
      }

      progressTracker?.scanFinished(now: Self.uptime)
      publishProgress()
      setSyncState(.syncing(.saving), generation: syncGeneration)

      if let syncPersister {
        beginSyncAction("Saving to the wallet database", calls: "BDK Wallet.persist (SQLite)", generation: syncGeneration)
        _ = try wallet.persist(persister: syncPersister)
      }

      // Verify wallet identity one more time after final await
      guard walletGeneration == syncGeneration else {
        addToLog("Sync completed but wallet replaced — discarding results")
        return
      }

      beginSyncAction(
        "Rebuilding the transaction, address and UTXO lists",
        calls: "Wallet.transactions, Wallet.listOutput, Wallet.listUnspent",
        generation: syncGeneration,
      )
      updateCachedData()
      pruneStaleeSavedPSBTs()
      endSyncAction("Finished", generation: syncGeneration)

      learnSyncPace(scanSeconds: scanSeconds, wallet: wallet, gap: gapLimit, clientWarm: clientWarm, profileId: syncProfileId)
      addToLog("Bar at \(Self.percent(progressTracker?.fraction)) before finishing")
      progressTracker?.finish()
      publishProgress()

      let now = Date()
      lastSyncDate = now
      if let profileId = syncProfileId {
        UserDefaults.standard.set(now, forKey: Self.lastSyncKey(profileId))
      }
      #if DEBUG
        // The screenshot tour's "Synced" age reads the same every run.
        let shownSyncDate = ScreenshotFixtures.isActive ? ScreenshotFixtures.lastSynced : now
      #else
        let shownSyncDate = now
      #endif
      setSyncState(.synced(shownSyncDate), generation: syncGeneration)

      let duration = String(format: "%.1f", now.timeIntervalSince(syncStartTime))
      let balanceDelta = Int64(balance) - Int64(balanceBefore)
      let balanceDeltaStr = balanceDelta >= 0 ? "+\(balanceDelta)" : "\(balanceDelta)"
      addToLog(
        "Sync completed successfully in \(duration)s: "
          + "balance \(balanceBefore) -> \(balance) sats (\(balanceDeltaStr)), "
          + "txs \(txCountBefore) -> \(transactions.count), "
          + "utxos \(utxoCountBefore) -> \(utxos.count), tip \(chainTipHeight)",
      )
    } catch {
      // If the wallet was replaced mid-sync (switch or reload), this failure —
      // typically a CancellationError — belongs to the old wallet. Don't clobber
      // the new wallet's connection state or sync status.
      guard walletGeneration == syncGeneration else {
        addToLog("Sync aborted after wallet replacement: \(error)")
        throw error
      }
      let errorMsg = "\(error)"
      endSyncAction("Failed: \(errorMsg)", generation: syncGeneration)
      addToLog("Sync failed with error: \(errorMsg)")
      let friendly = Self.friendlyElectrumError(error)
      electrumVerified = false
      electrumConnectionError = friendly
      setSyncState(.error(friendly), generation: syncGeneration)
      throw error
    }
  }

  /// Syncs a wallet that was just opened (a cold start, or a switch to it) unless it
  /// synced within `Constants.autoSyncInterval`. Pull to refresh, Sync Now and the
  /// auto-sync timer always sync.
  func syncOnOpen() async throws {
    guard let wallet else {
      addToLog("Sync failed: Wallet not loaded")
      throw AppError.walletNotLoaded
    }
    guard Self.syncedRecently(lastSync: lastSyncDate, now: Date(), hasSynced: wallet.latestCheckpoint().height > 0) else {
      try await sync(fullResync: false, trigger: .automatic)
      return
    }
    addToLog("Skipping sync on open: synced \(Int(timeSinceLastSync))s ago")
    await checkConnection()
  }

  /// Whether a wallet synced recently enough for opening it to skip a sync. One whose
  /// database has never synced always syncs, whatever the stored date says.
  nonisolated static func syncedRecently(lastSync: Date?, now: Date, hasSynced: Bool) -> Bool {
    guard hasSynced, let lastSync else { return false }
    let age = now.timeIntervalSince(lastSync)
    return age >= 0 && age < Constants.autoSyncInterval
  }

  private static func lastSyncKey(_ profileId: UUID) -> String {
    "lastSyncDate_\(profileId.uuidString)"
  }

  /// Pings the server and fetches its chain tip without a sync, for a wallet opened
  /// soon after its last one: the connection status and the confirmation counts stay
  /// current, and nothing on screen says it's syncing. It opens a new connection, as a
  /// sync does, with the same limit.
  private func checkConnection() async {
    guard let profile = currentProfile else { return }
    let network = NetworkMonitor.shared.state
    guard !network.isOffline else {
      electrumVerified = false
      electrumConnectionError = network.message
      addToLog("Connection check not started: \(network.logDescription)")
      return
    }
    let generation = walletGeneration
    let tipBefore = chainTipHeight
    let config = connectionConfig(for: profile)
    let deadline = Self.uptime + Constants.electrumConnectSeconds
    do {
      let client = try await Self.openConnection(to: config, until: deadline)
      guard walletGeneration == generation else { return }
      electrumClient = client
      try await Self.connecting(to: config, until: deadline) { try client.ping() }
      guard try await updateChainTip(from: client, config: config, until: deadline, generation: generation, profileId: profile.id) else {
        return
      }
      if chainTipHeight != tipBefore {
        updateCachedData()
      }
    } catch {
      guard walletGeneration == generation else { return }
      electrumVerified = false
      electrumConnectionError = Self.friendlyElectrumError(error)
      addToLog("Connection check failed: \(error)")
    }
  }

  /// Fetches the server's chain tip and records it, and that the server answered.
  /// False when the wallet was replaced while it waited. A server error keeps the
  /// saved tip; only running out of time to connect (`deadline`) throws.
  private func updateChainTip(
    from client: ElectrumClient,
    config: ElectrumConfig,
    until deadline: TimeInterval,
    generation: UInt64,
    profileId: UUID?,
  ) async throws -> Bool {
    let header = try await Self.connecting(to: config, until: deadline) { try? client.blockHeadersSubscribe() }
    guard let header else {
      addToLog("Chain tip fetch returned nothing; keeping tip \(chainTipHeight)")
      return walletGeneration == generation
    }
    guard walletGeneration == generation else { return false }
    chainTipHeight = UInt32(header.height)
    #if DEBUG
      // The screenshot tour's confirmation counts and locktime stay the same every run.
      if ScreenshotFixtures.isActive {
        chainTipHeight = ScreenshotFixtures.chainTipHeight
      }
    #endif
    if let profileId {
      UserDefaults.standard.set(Int(chainTipHeight), forKey: "chainTipHeight_\(profileId.uuidString)")
    }
    electrumVerified = true
    electrumConnectionError = nil
    addToLog("Chain tip height: \(chainTipHeight)")
    return true
  }

  // MARK: - Sync Progress

  private static var uptime: TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  private static func syncPaceKey(_ profileId: UUID) -> String {
    "syncSecondsPerUnit_\(profileId.uuidString)"
  }

  private static func clampedSecondsPerUnit(_ seconds: Double) -> Double {
    min(max(seconds, 0.01), 2)
  }

  private static func seconds(_ seconds: Double) -> String {
    String(format: "%.1fs", max(0, seconds))
  }

  private static func milliseconds(_ seconds: Double) -> String {
    "\(Int((seconds * 1000).rounded())) ms"
  }

  private static func percent(_ fraction: Double?) -> String {
    fraction.map { "\(Int($0 * 100))%" } ?? "sweeping (no estimate)"
  }

  /// Starts the bar for a new sync, and the ticker that moves it on between BDK's events
  private func startProgress(plan: SyncWorkPlan?, secondsPerUnit: Double, generation: UInt64) {
    progressTracker = SyncProgressTracker(
      plan: plan,
      secondsPerUnit: secondsPerUnit > 0 ? secondsPerUnit : SyncProgressTracker.defaultSecondsPerUnit,
      now: Self.uptime,
    )
    syncProgress = progressTracker?.fraction
    progressTicker?.cancel()
    progressTicker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self, walletGeneration == generation, syncState.isSyncing else { return }
        progressTracker?.tick(now: Self.uptime)
        publishProgress()
      }
    }
  }

  /// Publishes the tracker's fill when it has moved enough to redraw
  private func publishProgress() {
    let fraction = progressTracker?.fraction
    switch (fraction, syncProgress) {
    case let (new?, old?) where abs(new - old) < 0.001:
      return
    case (nil, nil):
      return
    default:
      syncProgress = fraction
    }
  }

  private func syncBatchStarted(keychain: KeychainKind, index: UInt32, at time: TimeInterval, generation: UInt64) {
    guard walletGeneration == generation, progressTracker != nil else { return }
    let keychain: UTXOItem.KeychainKind = keychain == .external ? .external : .internal
    progressTracker?.batchStarted(keychain: keychain, index: index, now: time)
    publishProgress()
    scanBatchNumber += 1
    let action = if let plan = progressTracker?.plan, let planned = plannedBatchCounts {
      plan.batchAction(keychain: keychain, index: index, scanBatch: scanBatchNumber, planned: planned)
    } else {
      SyncWorkPlan.unplannedBatchAction(keychain: keychain, index: index, batchSize: Constants.syncBatchSize, scanBatch: scanBatchNumber)
    }
    beginSyncAction(action.description, calls: action.calls, at: time, generation: generation)
  }

  /// Records what the sync is doing now. The connection sheet's Action row shows it,
  /// and the debug log gets it with the calls behind it, the time since the sync
  /// started, how long the step before it took, and the bar.
  private func beginSyncAction(_ description: String, calls: String, at time: TimeInterval? = nil, generation: UInt64) {
    guard walletGeneration == generation else { return }
    let now = time ?? Self.uptime
    let previous = syncAction.map { "; previous step \(Self.seconds(now - $0.startedAt))" } ?? ""
    syncAction = SyncAction(description: description, calls: calls, startedAt: now)
    addToLog("Sync +\(Self.seconds(now - syncStartUptime)): \(description). \(calls)\(previous); bar \(Self.percent(progressTracker?.fraction))")
  }

  /// Logs how the sync ended and clears the Action row
  private func endSyncAction(_ outcome: String, generation: UInt64) {
    guard walletGeneration == generation else { return }
    let now = Self.uptime
    let step = syncAction.map { " during \"\($0.description)\" after \(Self.seconds(now - $0.startedAt))" } ?? ""
    addToLog("Sync +\(Self.seconds(now - syncStartUptime)): \(outcome)\(outcome.hasPrefix("Failed") ? step : "")")
    syncAction = nil
  }

  /// What the saved wallet says a full scan will do (see `SyncWorkPlan`): how far
  /// each keychain has been used, where each transaction first appears in scan
  /// order, and how many of their parents aren't the wallet's own.
  private func syncWorkPlan(for wallet: Wallet, gap: Int, clientWarm: Bool) -> SyncWorkPlan {
    let txs = wallet.transactions().map(\.transaction)
    let lookup = Dictionary(
      txs.map { ($0.computeTxid().description, $0) },
      uniquingKeysWith: { first, _ in first },
    )
    func keychainIndex(_ script: Script) -> (keychain: UTXOItem.KeychainKind, index: UInt32)? {
      wallet.derivationOfSpk(spk: script).map { ($0.keychain == .external ? .external : .internal, $0.index) }
    }

    var lastUsed: [UTXOItem.KeychainKind: UInt32] = [:]
    var firstSeen: [(keychain: UTXOItem.KeychainKind, index: UInt32)] = []
    for tx in txs {
      var touched = tx.output().compactMap { keychainIndex($0.scriptPubkey) }
      if !tx.isCoinbase() {
        for input in tx.input() {
          guard let parent = lookup[input.previousOutput.txid.description] else { continue }
          let parentOutputs = parent.output()
          let vout = Int(input.previousOutput.vout)
          if vout < parentOutputs.count, let spent = keychainIndex(parentOutputs[vout].scriptPubkey) {
            touched.append(spent)
          }
        }
      }
      for address in touched {
        lastUsed[address.keychain] = max(lastUsed[address.keychain] ?? 0, address.index)
      }
      if let first = touched.min(by: { ($0.keychain == .external ? 0 : 1, $0.index) < ($1.keychain == .external ? 0 : 1, $1.index) }) {
        firstSeen.append(first)
      }
    }
    return SyncWorkPlan.make(
      lastUsed: lastUsed,
      gap: gap,
      batchSize: Constants.syncBatchSize,
      firstSeen: firstSeen,
      clientWarm: clientWarm,
    )
  }

  /// How many missing parents to download at once. Each download is a blocking call
  /// on a cooperative thread, so this stays well under the device's core count.
  private static let parentDownloadConcurrency = 4

  /// Downloads the outputs the wallet's transactions spend but it doesn't have: the
  /// inputs of payments received from outside, which their fees need. The scan runs
  /// with fetchPrevTxouts off, so it doesn't download every received payment's
  /// parent on every sync; this downloads each missing one once, and the wallet saves
  /// its outputs with the rest of its data. A parent that fails to download is tried
  /// again on the next sync, without failing this one.
  private func downloadMissingPrevouts(client: ElectrumClient, wallet: Wallet, generation: UInt64) async {
    var missing: [Txid: [OutPoint]] = [:]
    for canonical in wallet.transactions() where !canonical.transaction.isCoinbase() {
      do {
        _ = try wallet.calculateFee(tx: canonical.transaction)
      } catch let CalculateFeeError.MissingTxOut(outPoints) {
        for outpoint in outPoints {
          missing[outpoint.txid, default: []].append(outpoint)
        }
      } catch {
        continue
      }
    }
    guard !missing.isEmpty else {
      addToLog("No parent transactions to download: the wallet has every output its transactions spend")
      return
    }

    let outputCount = missing.values.reduce(0) { $0 + $1.count }
    beginSyncAction(
      "Downloading \(missing.count) parent \(missing.count == 1 ? "transaction" : "transactions") for the fees of received payments",
      calls: "\(missing.count) × blockchain.transaction.get for \(outputCount) \(outputCount == 1 ? "output" : "outputs") the wallet doesn't have, "
        + "\(Self.parentDownloadConcurrency) at a time",
      generation: generation,
    )
    var parents: [Txid: Transaction] = [:]
    var failed = 0
    await withTaskGroup(of: (Txid, Transaction?).self) { group in
      var pending = Array(missing.keys)
      for _ in 0 ..< min(Self.parentDownloadConcurrency, pending.count) {
        let txid = pending.removeLast()
        group.addTask { (txid, try? client.fetchTx(txid: txid)) }
      }
      for await (txid, parent) in group {
        // The server answers with the transaction it has under that txid; take it only
        // if it hashes to the txid asked for
        if let parent, parent.computeTxid() == txid {
          parents[txid] = parent
        } else {
          failed += 1
        }
        if let next = pending.popLast() {
          group.addTask { (next, try? client.fetchTx(txid: next)) }
        }
      }
    }
    guard walletGeneration == generation else { return }

    for (txid, outpoints) in missing {
      guard let outputs = parents[txid]?.output() else { continue }
      for outpoint in outpoints where Int(outpoint.vout) < outputs.count {
        wallet.insertTxout(outpoint: outpoint, txout: outputs[Int(outpoint.vout)])
      }
    }
    addToLog(
      "Downloaded \(parents.count) of \(missing.count) parent transactions"
        + (failed > 0 ? "; \(failed) failed and will be tried again on the next sync" : ""),
    )
  }

  /// Folds this sync's pace into the wallet's average, for the next sync's bar. Only
  /// a sync that fetched its transactions counts: over a warm connection they came
  /// from the cache, so its pace says nothing about the round trips.
  private func learnSyncPace(scanSeconds: Double, wallet: Wallet, gap: Int, clientWarm: Bool, profileId: UUID?) {
    let units = syncWorkPlan(for: wallet, gap: gap, clientWarm: clientWarm).scanUnits
    guard let profileId, units > 0, scanSeconds > 0 else { return }
    let measured = scanSeconds / units
    guard !clientWarm else {
      addToLog("Sync pace over a warm connection: \(Self.milliseconds(measured)) per estimated round trip (\(Int(units)) estimated)")
      return
    }
    let key = Self.syncPaceKey(profileId)
    let previous = UserDefaults.standard.double(forKey: key)
    let clamped = Self.clampedSecondsPerUnit(measured)
    let learned = previous > 0 ? previous + (clamped - previous) * 0.3 : clamped
    UserDefaults.standard.set(learned, forKey: key)
    addToLog("Sync pace: \(Self.milliseconds(measured)) per round trip over \(Int(units)); average now \(Self.milliseconds(learned))")
  }

  /// Tests connectivity by fetching the chain tip from the server.
  /// For SSL connections, validates the certificate first with a native TLS check
  /// to detect self-signed certs before BDK obscures the error.
  /// Returns the block height on success.
  @discardableResult
  func testElectrumConnection(config: ElectrumConfig) async throws -> UInt32 {
    try Self.requireNetwork()
    // The certificate check and BDK's connection share one connect limit
    let deadline = Self.uptime + Constants.electrumConnectSeconds
    // Pre-check SSL certificate before handing off to BDK
    if config.useSSL, !config.allowInsecureSSL {
      try await Self.validateTLSCertificate(host: config.host, port: config.port, until: deadline)
    }

    let url = config.url
    let validateDomain = !config.allowInsecureSSL
    let header = try await Self.connecting(to: config, until: deadline) {
      let client = try Self.makeElectrumClient(url: url, validateDomain: validateDomain)
      return try client.blockHeadersSubscribe()
    }
    return UInt32(header.height)
  }

  /// Throws the offline message while the phone has no network, so a connection test
  /// or a fee estimate doesn't try to connect
  private static func requireNetwork() throws {
    let network = NetworkMonitor.shared.state
    if network.isOffline {
      throw AppError.electrumConnectionFailed(network.message)
    }
  }

  /// Known genesis block nonces for network verification.
  private static let genesisNonce: [BitcoinNetwork: UInt32] = [
    .mainnet: 2_083_236_893,
    .testnet3: 414_098_458,
    .testnet4: 393_743_547,
  ]

  /// Detects which network an Electrum server is on by checking its genesis block nonce.
  /// Returns nil for unknown networks (e.g. signet).
  func detectElectrumNetwork(config: ElectrumConfig) async throws -> BitcoinNetwork? {
    try Self.requireNetwork()
    // The certificate check and BDK's connection share one connect limit
    let deadline = Self.uptime + Constants.electrumConnectSeconds
    if config.useSSL, !config.allowInsecureSSL {
      try await Self.validateTLSCertificate(host: config.host, port: config.port, until: deadline)
    }

    let url = config.url
    let validateDomain = !config.allowInsecureSSL
    let genesisHeader = try await Self.connecting(to: config, until: deadline) {
      let client = try Self.makeElectrumClient(url: url, validateDomain: validateDomain)
      return try client.blockHeader(height: 0)
    }

    for (network, nonce) in Self.genesisNonce where genesisHeader.nonce == nonce {
      return network
    }
    return nil
  }

  /// Performs a native TLS handshake to validate the server's certificate.
  /// Throws a clear error if the certificate is self-signed or untrusted, or if the
  /// server can't be reached by `deadline` (system uptime).
  private static func validateTLSCertificate(host: String, port: UInt16, until deadline: TimeInterval) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let queue = DispatchQueue(label: "tls-check")
      let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tls,
      )
      // The handshake and the deadline race, and whichever comes first ends the check
      let once = ResumeOnce(continuation)
      let finish: @Sendable (Result<Void, Error>) -> Void = { result in
        connection.cancel()
        once.resume(with: result)
      }

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          finish(.success(()))
        case let .waiting(error):
          finish(.failure(tlsCheckError(waiting: error, host: host, port: port)))
        case let .failed(error):
          let desc = error.localizedDescription
          if desc.contains("certificate") || desc.contains("SSL") || desc.contains("trust") {
            finish(.failure(AppError.electrumConnectionFailed(
              "SSL certificate rejected for \(host):\(port) — the server may use a self-signed certificate. Try using TCP instead of SSL, or use a server with a CA-signed certificate.",
            )))
          } else {
            finish(.failure(AppError.electrumConnectionFailed(
              "Connection to \(host):\(port) failed: \(desc)",
            )))
          }
        case .cancelled:
          break
        default:
          break
        }
      }

      // Without it, a server that never answers holds the check in .preparing until
      // the system's TCP connect timeout, about 75 s
      queue.asyncAfter(deadline: .now() + max(deadline - uptime, 0)) {
        finish(.failure(connectTimedOut(host: host, port: port)))
      }

      connection.start(queue: queue)
    }
  }

  /// What the TLS check says when its connection is left waiting. Only a TLS error is
  /// about the certificate. A POSIX or DNS error, such as a refused or timed-out
  /// connection, means the server couldn't be reached.
  nonisolated static func tlsCheckError(waiting error: NWError, host: String, port: UInt16) -> AppError {
    switch error {
    case let .tls(status) where status == errSecCertificateExpired:
      .electrumConnectionFailed("SSL certificate expired on \(host):\(port).")
    case .tls:
      .electrumConnectionFailed(
        "SSL certificate rejected for \(host):\(port) — the server may use a self-signed certificate. Try using TCP instead of SSL, or use a server with a CA-signed certificate.",
      )
    case let .posix(code):
      .electrumConnectionFailed("Couldn't reach \(host):\(port) (\(String(cString: strerror(code.rawValue))))")
    case .dns:
      .electrumConnectionFailed("Couldn't reach \(host):\(port) (DNS lookup failed)")
    default:
      .electrumConnectionFailed("Couldn't reach \(host):\(port) (\(error.localizedDescription))")
    }
  }

  // MARK: - Data Queries

  private func updateCachedData() {
    guard let wallet else { return }

    let bal = wallet.balance()
    balance = bal.total.toSat()

    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)

    let txList = wallet.transactions()
    // Build lookup for O(1) input resolution instead of O(n) per input
    let txLookup = Dictionary(
      txList.map { ($0.transaction.computeTxid().description, $0.transaction) },
      uniquingKeysWith: { first, _ in first },
    )
    // The server's tip, or failing that the wallet's own: applying a scan moves
    // BDK's checkpoint to the tip the server reported, even when the header fetch
    // in sync() came back empty.
    var tipHeight = max(chainTipHeight, wallet.latestCheckpoint().height)
    #if DEBUG
      // The screenshot tour's confirmation counts stay the same every run, even where
      // BDK's checkpoint has moved past the fixed chain tip
      if ScreenshotFixtures.isActive {
        tipHeight = ScreenshotFixtures.chainTipHeight
      }
    #endif
    transactions = txList.map { canonicalTx -> TransactionItem in
      let tx = canonicalTx.transaction
      let txid = tx.computeTxid().description

      let sentAndReceived = wallet.sentAndReceived(tx: tx)
      let sent = sentAndReceived.sent.toSat()
      let received = sentAndReceived.received.toSat()

      let isIncoming = received > sent
      let amount: Int64 = isIncoming ? Int64(received - sent) : -Int64(sent - received)

      var confirmations: UInt32 = 0
      var confirmationsKnown = true
      var timestamp: Date?
      var blockHeight: UInt32?
      var firstSeen: Date?

      switch canonicalTx.chainPosition {
      case let .confirmed(confirmationBlockTime, _):
        let minedHeight = confirmationBlockTime.blockId.height
        blockHeight = minedHeight
        if let count = TransactionItem.confirmations(blockHeight: minedHeight, tipHeight: tipHeight) {
          confirmations = count
        } else {
          // Confirmed, but how deep isn't known until a tip is seen
          confirmations = 1
          confirmationsKnown = false
        }
        if confirmationBlockTime.confirmationTime > 0 {
          timestamp = Date(timeIntervalSince1970: TimeInterval(confirmationBlockTime.confirmationTime))
        }
        // Cleanup firstSeen if tx is now confirmed
        let defaultKey = "firstSeen_\(txid)"
        if UserDefaults.standard.object(forKey: defaultKey) != nil {
          UserDefaults.standard.removeObject(forKey: defaultKey)
        }
      case let .unconfirmed(lastSeen):
        confirmations = 0
        timestamp = nil
        if let lastSeen, lastSeen > 0 {
          let defaultKey = "firstSeen_\(txid)"
          let stored = UserDefaults.standard.double(forKey: defaultKey)
          if stored > 0 {
            firstSeen = Date(timeIntervalSince1970: stored)
          } else {
            firstSeen = Date(timeIntervalSince1970: TimeInterval(lastSeen))
            UserDefaults.standard.set(TimeInterval(lastSeen), forKey: defaultKey)
          }
        }
      }

      let feeAmount: UInt64? = (try? wallet.calculateFee(tx: tx).toSat())
      let txVsize = tx.vsize()

      // Extract outputs
      let outputs: [TransactionItem.TxIO] = tx.output().map { txOut in
        let address = (try? Address.fromScript(script: txOut.scriptPubkey, network: network).description) ?? "Unknown"
        let mine = wallet.isMine(script: txOut.scriptPubkey)
        return TransactionItem.TxIO(
          address: address,
          amount: txOut.value.toSat(),
          prevTxid: nil,
          prevVout: nil,
          isMine: mine,
        )
      }

      // Extract inputs (resolve address and amount from previous output when possible)
      let inputs: [TransactionItem.TxIO] = tx.input().map { txIn in
        let prevTxid = txIn.previousOutput.txid.description
        let prevVout = txIn.previousOutput.vout
        var inputAmount: UInt64 = 0
        var mine = false
        var address = prevTxid.truncatedMiddle() + ":\(prevVout)"
        if let prevTx = txLookup[prevTxid] {
          let prevOutputs = prevTx.output()
          if prevVout < prevOutputs.count {
            let prevOut = prevOutputs[Int(prevVout)]
            inputAmount = prevOut.value.toSat()
            mine = wallet.isMine(script: prevOut.scriptPubkey)
            if let addr = try? Address.fromScript(script: prevOut.scriptPubkey, network: network).description {
              address = addr
            }
          }
        }
        return TransactionItem.TxIO(
          address: address,
          amount: inputAmount,
          prevTxid: prevTxid,
          prevVout: prevVout,
          isMine: mine,
        )
      }

      return TransactionItem(
        id: txid,
        amount: amount,
        fee: feeAmount,
        confirmations: confirmations,
        confirmationsKnown: confirmationsKnown,
        timestamp: timestamp,
        isIncoming: isIncoming,
        blockHeight: blockHeight,
        vsize: txVsize,
        firstSeen: firstSeen,
        inputs: inputs,
        outputs: outputs,
      )
    }.sorted {
      let isUnconfirmed0 = $0.confirmations == 0
      let isUnconfirmed1 = $1.confirmations == 0
      if isUnconfirmed0 != isUnconfirmed1 {
        return isUnconfirmed0
      }
      return ($0.timestamp ?? $0.firstSeen ?? .distantPast) > ($1.timestamp ?? $1.firstSeen ?? .distantPast)
    }

    let txDates = Dictionary(
      transactions.map { ($0.id, $0.timestamp ?? $0.firstSeen ?? .distantPast) },
      uniquingKeysWith: { first, _ in first },
    )
    outputs = wallet.listOutput().map { output in
      let confirmed = switch output.chainPosition {
      case .confirmed: true
      case .unconfirmed: false
      }
      return UTXOItem(
        txid: output.outpoint.txid.description,
        vout: output.outpoint.vout,
        amount: output.txout.value.toSat(),
        isConfirmed: confirmed,
        keychain: output.keychain == .external ? .external : .internal,
        derivationIndex: output.derivationIndex,
        isSpent: output.isSpent,
      )
    }.sorted { u0, u1 in
      let isUnconfirmed0 = !u0.isConfirmed
      let isUnconfirmed1 = !u1.isConfirmed
      if isUnconfirmed0 != isUnconfirmed1 {
        return isUnconfirmed0
      }
      return (txDates[u0.txid] ?? .distantPast) > (txDates[u1.txid] ?? .distantPast)
    }
    utxos = outputs.filter { !$0.isSpent }
    logger.debug("Outputs: \(outputs.count) total, \(utxos.count) unspent, \(outputs.count - utxos.count) spent")
  }

  // MARK: - Saved PSBT Pruning

  /// Remove saved PSBTs whose inputs have been spent (no longer in the UTXO set).
  private func pruneStaleeSavedPSBTs() {
    guard let walletID = currentProfile?.id,
          let container = modelContainer else { return }

    let currentOutpoints = Set(utxos.map(\.id)) // "txid:vout"

    do {
      let context = ModelContext(container)
      let descriptor = FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.walletID == walletID })
      let savedPSBTs = try context.fetch(descriptor)

      for saved in savedPSBTs {
        let inputOutpoints = saved.inputOutpoints
          .split(separator: ",")
          .map(String.init)
          .filter { !$0.isEmpty }

        // If we have no stored outpoints, skip (legacy saved PSBTs before this field existed)
        guard !inputOutpoints.isEmpty else { continue }

        // If any input is no longer in the UTXO set, the PSBT is stale
        let hasSpentInput = inputOutpoints.contains { !currentOutpoints.contains($0) }
        if hasSpentInput {
          // RBF PSBTs spend the same inputs as the original transaction.
          // Don't prune if the original transaction is still unconfirmed (replaceable).
          if let originalTxid = saved.originalTxid,
             let originalTx = transactions.first(where: { $0.id == originalTxid }),
             !originalTx.isConfirmed
          {
            continue
          }
          addToLog("Pruning stale saved PSBT '\(saved.name)': input spent")
          context.delete(saved)
        }
      }

      try context.save()
    } catch {
      addToLog("Failed to prune saved PSBTs: \(error)")
    }
  }

  // MARK: - Addresses

  /// A receive address to show, and whether Next Address has another after it
  struct ReceiveAddress: Equatable {
    let address: String
    let index: UInt32
    /// False when every later address a sync would check is used or labeled
    let hasNext: Bool
  }

  /// The gap limit a sync scans the receive chain with
  var receiveGapLimit: Int {
    currentProfile?.scanGapLimit ?? Constants.defaultAddressGap
  }

  /// The receive address to hand out: the lowest-index one that has no
  /// transactions and no label. Nil when there is none within the gap limit.
  func getNextAddress() throws -> ReceiveAddress? {
    try receiveAddress(from: 0)
  }

  /// "Next Address": the first available receive address after `index`, or nil
  /// when there is none within the gap limit.
  func getNextAddress(after index: UInt32) throws -> ReceiveAddress? {
    guard index < UInt32.max else { return nil }
    return try receiveAddress(from: index + 1)
  }

  /// Whether Next Address has an address to give after `index`. Looks without
  /// revealing anything.
  func hasReceiveAddress(after index: UInt32) -> Bool {
    guard let wallet, index < UInt32.max else { return false }
    return Self.firstAvailableReceiveAddress(
      in: wallet,
      from: index + 1,
      taken: takenReceiveAddresses(),
      maxIndex: receiveIndexCap(),
    ) != nil
  }

  private func receiveAddress(from start: UInt32) throws -> ReceiveAddress? {
    guard let wallet else { throw AppError.walletNotLoaded }
    let taken = takenReceiveAddresses()
    let cap = receiveIndexCap()
    guard let available = Self.availableReceiveAddress(in: wallet, from: start, taken: taken, maxIndex: cap) else {
      logger.info("No receive address left within the gap limit (\(receiveGapLimit)): every one up to #\(cap) is used or labeled")
      return nil
    }
    let info = available.info
    if available.didReveal {
      if let persister {
        _ = try wallet.persist(persister: persister)
      } else {
        logger.warning("Address revealed without persister — derivation state may be lost")
      }
    }
    let hasNext = info.index < UInt32.max
      && Self.firstAvailableReceiveAddress(in: wallet, from: info.index + 1, taken: taken, maxIndex: cap) != nil
    return ReceiveAddress(address: info.address.description, index: info.index, hasNext: hasNext)
  }

  /// Receive addresses that count as handed out: every one with a transaction, and
  /// every labeled one. A labeled address counts even before it is paid, so it isn't
  /// offered to someone else while that payment is still outstanding.
  private func takenReceiveAddresses() -> Set<String> {
    var taken = buildUsedAddressSet()
    if let walletID = currentProfile?.id, let container = modelContainer {
      taken.formUnion(LabelService.labeledAddresses(walletID: walletID, context: container.mainContext))
    }
    return taken
  }

  /// The highest receive index a sync checks, so the highest Birch hands out
  private func receiveIndexCap() -> UInt32 {
    Self.receiveIndexCap(lastUsed: wallet.flatMap(Self.lastUsedReceiveIndex), gap: receiveGapLimit)
  }

  /// The highest receive index a sync checks. A full scan stops at the gap-th unused
  /// address in a row, so it reaches `lastUsed + gap`, or `gap - 1` when no receive
  /// address has a transaction yet. Funds sent to any later address would not be
  /// found, by Birch or by a restore with the same gap limit.
  nonisolated static func receiveIndexCap(lastUsed: UInt32?, gap: Int) -> UInt32 {
    let gap = UInt32(clamping: max(gap, 1))
    guard let lastUsed else { return gap - 1 }
    let (cap, overflow) = lastUsed.addingReportingOverflow(gap)
    return overflow ? .max : cap
  }

  /// The highest receive index with a transaction paying it, per the wallet's own
  /// script index, or nil when no receive address has one
  static func lastUsedReceiveIndex(in wallet: Wallet) -> UInt32? {
    var lastUsed: UInt32?
    for canonicalTx in wallet.transactions() {
      for output in canonicalTx.transaction.output() {
        guard let derivation = wallet.derivationOfSpk(spk: output.scriptPubkey),
              derivation.keychain == .external else { continue }
        lastUsed = max(lastUsed ?? 0, derivation.index)
      }
    }
    return lastUsed
  }

  /// The first receive address from `start` through `maxIndex` that isn't in `taken`,
  /// or nil when there is none. Only looks: nothing is revealed.
  static func firstAvailableReceiveAddress(
    in wallet: Wallet,
    from start: UInt32,
    taken: Set<String>,
    maxIndex: UInt32,
  ) -> AddressInfo? {
    var index = start
    while index <= maxIndex {
      let info = wallet.peekAddress(keychain: .external, index: index)
      if !taken.contains(info.address.description) {
        return info
      }
      guard index < maxIndex else { break }
      index += 1
    }
    return nil
  }

  /// The first receive address from `start` through `maxIndex` that isn't in
  /// `taken`, or nil when there is none. The address returned is revealed if it
  /// wasn't already, so BDK's derivation index records it as handed out. Revealing
  /// up to an index is a no-op once that index is revealed, so looking at an address
  /// never moves the wallet's derivation index, and nothing is revealed when there
  /// is no address to return.
  static func availableReceiveAddress(
    in wallet: Wallet,
    from start: UInt32,
    taken: Set<String>,
    maxIndex: UInt32,
  ) -> (info: AddressInfo, didReveal: Bool)? {
    guard let info = firstAvailableReceiveAddress(in: wallet, from: start, taken: taken, maxIndex: maxIndex) else {
      return nil
    }
    let revealed = wallet.revealAddressesTo(keychain: .external, index: info.index)
    return (info, !revealed.isEmpty)
  }

  func getAddresses(keychain: UTXOItem.KeychainKind) -> [AddressItem] {
    guard let wallet else { return [] }
    let bdkKeychain: KeychainKind = keychain == .external ? .external : .internal
    let usedAddresses = buildUsedAddressSet()
    let gapLimit = currentProfile?.scanGapLimit ?? Constants.defaultAddressGap

    // Scan addresses, always ensuring gapLimit unused addresses after the last used one.
    // We extend the scan window each time we find a used address.
    var items: [AddressItem] = []
    var lastUsedIndex: Int = -1
    var i: UInt32 = 0

    while Int(i) <= lastUsedIndex + gapLimit {
      let info = wallet.peekAddress(keychain: bdkKeychain, index: i)
      let addr = info.address.description
      let isUsed = usedAddresses.contains(addr)
      if isUsed {
        lastUsedIndex = Int(i)
      }
      items.append(AddressItem(
        index: i,
        address: addr,
        isUsed: isUsed,
        isChange: keychain == .internal,
      ))
      i += 1
    }

    return items
  }

  private func buildUsedAddressSet() -> Set<String> {
    guard let wallet else { return [] }
    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    var addresses = Set<String>()
    for canonicalTx in wallet.transactions() {
      for output in canonicalTx.transaction.output() {
        if let addr = try? Address.fromScript(script: output.scriptPubkey, network: network).description {
          addresses.insert(addr)
        }
      }
    }
    return addresses
  }

  // MARK: - Fee Estimation

  struct RecommendedFees {
    let fast: Double // Target: ~1 block
    let medium: Double // Target: ~3–6 blocks
    let slow: Double // Target: ~economy

    /// Used when live fee estimation is unavailable (e.g. Electrum not yet
    /// connected). A conservative flat rate so the send / bump-fee flow stays
    /// usable instead of leaving the fee field empty.
    static let fallback = RecommendedFees(fast: 1.5, medium: 1.5, slow: 1.5)

    /// The "Fixed Default" fee source's rates.
    static let fixed = RecommendedFees(fast: 5.0, medium: 2.0, slow: 1.0)
  }

  /// Fetches estimated fee rates in sats/vB, dispatching to the selected source
  func getFeeRates() async throws -> RecommendedFees {
    #if DEBUG
      // The screenshot tour uses the fixed rates, while Settings keeps showing the
      // default source.
      if ScreenshotFixtures.isActive {
        return .fixed
      }
    #endif
    let sourceRaw = UserDefaults.standard.string(forKey: Constants.feeSourceKey) ?? FeeSource.electrum.rawValue
    let source = FeeSource(rawValue: sourceRaw) ?? .electrum
    let generation = walletGeneration

    let fees: RecommendedFees
    do {
      fees = switch source {
      case .mempoolSpace:
        try await fetchMempoolFees()
      case .electrum:
        try await fetchElectrumFees()
      case .fixed:
        .fixed
      }
    } catch {
      logger.error("Fee estimation from \(source.rawValue) failed: \(error)")
      throw error
    }
    // The rates came from this wallet's network and server, so they must not reach
    // the Send or Bump Fee screen of a wallet loaded while they were fetched
    guard walletGeneration == generation else {
      logger.info("Discarded fee estimates from \(source.rawValue): the wallet changed while they were fetched")
      throw CancellationError()
    }
    logger.info(
      "Fee estimates from \(source.rawValue): fast \(fees.fast), medium \(fees.medium), slow \(fees.slow) sat/vB",
    )
    return fees
  }

  private func fetchMempoolFees() async throws -> RecommendedFees {
    let base = switch currentProfile?.bitcoinNetwork {
    case .mainnet: "https://mempool.space"
    case .testnet4: "https://mempool.space/testnet4"
    case .testnet3: "https://mempool.space/testnet"
    case .signet: "https://mempool.space/signet"
    case nil: "https://mempool.space"
    }
    guard !NetworkMonitor.shared.state.isOffline else { throw URLError(.notConnectedToInternet) }
    let url = URL(string: "\(base)/api/v1/fees/precise")!
    // The Electrum socket timeout, instead of URLSession's 60 s
    let request = URLRequest(url: url, timeoutInterval: TimeInterval(Constants.electrumTimeoutSeconds))
    let (data, _) = try await URLSession.shared.data(for: request)
    let decoded = try JSONDecoder().decode(MempoolPreciseFees.self, from: data)
    // An absurd estimate is treated like a failed fetch, so callers use the fallback rates.
    let rates = [decoded.fastestFee, decoded.halfHourFee, decoded.economyFee]
    guard rates.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= InputLimits.maxFeeRate }) else {
      throw AppError.syncFailed("mempool.space returned an out-of-range fee estimate: \(rates)")
    }
    return RecommendedFees(
      fast: decoded.fastestFee,
      medium: decoded.halfHourFee,
      slow: decoded.economyFee,
    )
  }

  private struct MempoolPreciseFees: Decodable {
    let fastestFee: Double
    let halfHourFee: Double
    let hourFee: Double
    let economyFee: Double
    let minimumFee: Double
  }

  private func fetchElectrumFees() async throws -> RecommendedFees {
    guard let profile = currentProfile else { throw AppError.walletNotLoaded }
    try Self.requireNetwork()
    let config = connectionConfig(for: profile)
    let url = config.url
    let validateDomain = !config.allowInsecureSSL

    // Electrum returns BTC/kB. To convert to sats/vB:
    // BTC -> sats = * 100,000,000
    // kB -> vB = / 1000
    // So multiplier is 100,000
    let multiplier: Double = 100_000

    // A new connection, as a sync opens, so one left idle since the last sync can't
    // hold the fee step up. Connecting and the three estimates share the connect limit;
    // past it, Send and Bump Fee use the fallback rates.
    return try await Self.connecting(to: config, until: Self.uptime + Constants.electrumConnectSeconds) {
      let electrumClient = try Self.makeElectrumClient(url: url, validateDomain: validateDomain)
      let highRaw = try? electrumClient.estimateFee(number: 1)
      let medRaw = try? electrumClient.estimateFee(number: 6)
      let lowRaw = try? electrumClient.estimateFee(number: 144)

      var highRate = (highRaw ?? -1) * multiplier
      var medRate = (medRaw ?? -1) * multiplier
      var lowRate = (lowRaw ?? -1) * multiplier

      // Sanity cap: Testnet electrum servers sometimes return absurdly high values.
      let maxSaneRate = 500.0
      if highRate > maxSaneRate {
        highRate = 5.0
      }
      if medRate > maxSaneRate {
        medRate = 2.0
      }
      if lowRate > maxSaneRate {
        lowRate = 1.0
      }

      let fast = highRate > 0 ? highRate : 5.0
      var medium = medRate > 0 ? medRate : 2.0
      var slow = lowRate > 0 ? lowRate : 1.0

      // Ensure fees are monotonically decreasing: fast >= medium >= slow
      if medium > fast {
        medium = fast
      }
      if slow > medium {
        slow = medium
      }

      return RecommendedFees(
        fast: fast,
        medium: medium,
        slow: slow,
      )
    }
  }

  // MARK: - PSBT

  struct PSBTResult {
    let base64: String
    let bytes: Data
    let fee: UInt64
    let changeAmount: UInt64?
    let changeAddress: String?
    let inputCount: Int
  }

  /// Converts sat/vB to BDK's sat/kwu, refusing a rate that is not finite,
  /// not positive or above `InputLimits.maxFeeRate` instead of trapping.
  private func makeFeeRate(satPerVb feeRate: Double) throws -> FeeRate {
    guard feeRate.isFinite, feeRate > 0, feeRate <= InputLimits.maxFeeRate else {
      throw AppError.psbtCreationFailed(
        "Fee rate must be between 0 and \(formatFeeRate(InputLimits.maxFeeRate)) sat/vB",
      )
    }
    let satKwu = max(UInt64(round(feeRate * 250.0)), 1)
    return FeeRate.fromSatPerKwu(satKwu: satKwu)
  }

  func createPSBT(
    recipients: [(address: String, amount: UInt64, isSendMax: Bool)],
    feeRate: Double,
    utxos: [(txid: String, vout: UInt32)]? = nil,
    unspendable: Set<String> = [],
  ) async throws -> PSBTResult {
    guard let wallet else { throw AppError.walletNotLoaded }

    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let bdkFeeRate = try makeFeeRate(satPerVb: feeRate)

    let safeHeight = chainTipHeight > 0 ? chainTipHeight - 1 : 0
    var builder = TxBuilder()
      .feeRate(feeRate: bdkFeeRate)
      .addGlobalXpubs()
      .nlocktime(locktime: .blocks(height: safeHeight))

    // Pass frozen outpoints to BDK so automatic coin selection skips them.
    // Note: BDK lets explicit addUtxos() entries override the unspendable list,
    // so manual selection is unaffected here.
    if !unspendable.isEmpty {
      let frozenOutpoints = unspendable.compactMap { str -> OutPoint? in
        let parts = str.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let vout = UInt32(parts[1]) else { return nil }
        return try? OutPoint(txid: Txid.fromString(hex: String(parts[0])), vout: vout)
      }
      if !frozenOutpoints.isEmpty {
        builder = builder.unspendable(unspendable: frozenOutpoints)
      }
    }

    #if DEBUG
      // The screenshot tour builds the same transaction every run: coins picked
      // largest first and kept in order, where BDK would pick and shuffle them at random.
      var utxos = utxos
      if ScreenshotFixtures.isActive {
        builder = builder.ordering(ordering: .untouched)
        if utxos?.isEmpty ?? true, !recipients.contains(where: \.isSendMax) {
          utxos = ScreenshotFixtures.coins(
            from: self.utxos.filter { !unspendable.contains($0.id) },
            amount: InputLimits.sum(recipients.map(\.amount)),
            feeRate: feeRate,
            outputs: recipients.count + 1,
          )
        }
      }
    #endif

    // Manual UTXO selection (addUtxos takes priority over the unspendable list in BDK)
    if let utxos, !utxos.isEmpty {
      let outpoints = try utxos.map { try OutPoint(txid: Txid.fromString(hex: $0.txid), vout: $0.vout) }
      builder = builder.addUtxos(outpoints: outpoints).manuallySelectedOnly()
    }

    for recipient in recipients {
      let address = try Address(address: recipient.address, network: network)
      let script = address.scriptPubkey()

      if recipient.isSendMax {
        builder = builder.drainTo(script: script).drainWallet()
      } else {
        builder = builder.addRecipient(script: script, amount: Amount.fromSat(satoshi: recipient.amount))
      }
    }

    let psbt = try builder.finish(wallet: wallet)
    let fee = try psbt.fee()

    let inputCount = psbt.input().count

    // Change is whatever came back on the internal keychain, per the wallet's own
    // script index — a self-send to one of our receive addresses stays a recipient.
    let change = changeOutput(of: psbt, network: network)
    let changeAmount = change?.amount
    let changeAddress = change?.address

    let base64 = psbt.serialize()
    guard let bytes = Data(base64Encoded: base64) else {
      logger.error("PSBT creation failed: could not decode serialized PSBT base64")
      throw AppError.psbtFinalizeFailed("Failed to decode PSBT base64")
    }
    let recipientSummary = recipients
      .map { "\($0.isSendMax ? "max" : "\($0.amount)") sats to \($0.address)" }
      .joined(separator: ", ")
    logger.info(
      "Created PSBT: \(inputCount) inputs, \(recipients.count) recipients [\(recipientSummary)], "
        + "fee \(fee) sats @ \(feeRate) sat/vB\(changeAddress.map { ", change \(changeAmount ?? 0) sats to \($0)" } ?? "")",
    )
    return PSBTResult(base64: base64, bytes: bytes, fee: fee, changeAmount: changeAmount, changeAddress: changeAddress, inputCount: inputCount)
  }

  func createBumpFeePSBT(txid: String, feeRate: Double) async throws -> PSBTResult {
    guard let wallet else { throw AppError.walletNotLoaded }

    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let bdkFeeRate = try makeFeeRate(satPerVb: feeRate)

    let safeHeight = chainTipHeight > 0 ? chainTipHeight - 1 : 0
    let bdkTxid = try Txid.fromString(hex: txid)
    let psbt = try BumpFeeTxBuilder(txid: bdkTxid, feeRate: bdkFeeRate)
      .nlocktime(locktime: .blocks(height: safeHeight))
      .finish(wallet: wallet)
    let fee = try psbt.fee()

    let inputCount = psbt.input().count

    // Same rule as createPSBT: only an internal-keychain output is change. The
    // original transaction's recipients stay recipients, including self-sends.
    let change = changeOutput(of: psbt, network: network)
    let changeAmount = change?.amount
    let changeAddress = change?.address

    let base64 = psbt.serialize()
    guard let bytes = Data(base64Encoded: base64) else {
      throw AppError.psbtFinalizeFailed("Failed to decode PSBT base64")
    }
    return PSBTResult(base64: base64, bytes: bytes, fee: fee, changeAmount: changeAmount, changeAddress: changeAddress, inputCount: inputCount)
  }

  func combinePSBTs(original: Data, signed: Data) async throws -> (String, Data) {
    let originalBase64 = original.base64EncodedString()
    let signedBase64 = signed.base64EncodedString()

    let psbt = try Psbt(psbtBase64: originalBase64)
    let signedPsbt = try Psbt(psbtBase64: signedBase64)

    // BDK's combine() enforces that the unsigned transaction matches at the BIP-174
    // level — structurally incompatible PSBTs are rejected. No additional validation needed.
    let combined = try psbt.combine(other: signedPsbt)

    let base64 = combined.serialize()
    guard let bytes = Data(base64Encoded: base64) else {
      throw AppError.psbtCombineFailed("Failed to decode combined PSBT base64")
    }
    return (base64, bytes)
  }

  func finalizePSBT(_ psbtData: Data) throws -> (psbt: Psbt, tx: Transaction) {
    guard let wallet else { throw AppError.walletNotLoaded }

    let base64 = psbtData.base64EncodedString()
    let psbt = try Psbt(psbtBase64: base64)

    // Never finalize a PSBT whose declared input amounts contradict wallet state —
    // this is the single choke point ahead of both the Ready-to-Broadcast screen
    // (via finalizeTx) and broadcastPSBT. Warnings are logged but do not block.
    if let critical = verifyPSBT(psbt).criticals.first {
      throw AppError.psbtFinalizeFailed(critical.message)
    }

    // Use wallet.finalizePsbt which has full wallet context for finalizing
    // scripts (e.g. policy-based spending conditions). Falls back to psbt.finalize()
    // if the wallet method fails.
    let finalized: Bool
    do {
      finalized = try wallet.finalizePsbt(psbt: psbt)
    } catch {
      // wallet.finalizePsbt may throw SignerError; fall back to standalone finalize
      let result = psbt.finalize()
      guard result.couldFinalize else {
        let errorDetails = result.errors?.map { "\($0)" }.joined(separator: ", ") ?? "Unknown finalization error"
        throw AppError.psbtFinalizeFailed(errorDetails)
      }
      let tx = try result.psbt.extractTx()
      return (result.psbt, tx)
    }

    guard finalized else {
      throw AppError.psbtFinalizeFailed("Wallet could not finalize PSBT")
    }

    let tx = try psbt.extractTx()
    return (psbt, tx)
  }

  /// Whether an address belongs to the loaded wallet (self-transfer detection)
  func isWalletAddress(_ address: String) -> Bool {
    guard let wallet else { return false }
    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let addr = try? Address(address: trimmed, network: network) else { return false }
    return wallet.isMine(script: addr.scriptPubkey())
  }

  func psbtInputOutpoints(_ psbtData: Data) -> [String] {
    let base64 = psbtData.base64EncodedString()
    guard let psbt = try? Psbt(psbtBase64: base64),
          let tx = try? psbt.extractTx() else { return [] }
    return tx.input().map { "\($0.previousOutput.txid):\($0.previousOutput.vout)" }
  }

  /// Returns the output index (vout) of the given address in the PSBT's transaction outputs.
  func psbtChangeVout(_ psbtData: Data, changeAddress: String) -> UInt32? {
    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    guard let psbt = try? Psbt(psbtBase64: psbtData.base64EncodedString()),
          let tx = try? psbt.extractTx() else { return nil }
    for (i, output) in tx.output().enumerated() {
      if let addr = try? Address.fromScript(script: output.scriptPubkey, network: network).description,
         addr == changeAddress
      {
        return UInt32(i)
      }
    }
    return nil
  }

  // MARK: - PSBT Inspection

  /// Resolves a script to the keychain and index the wallet derived it from, or nil if
  /// the wallet has no record of it. Backs every output classification.
  private var derivationLookup: (Script) -> KeychainAndIndex? {
    guard let wallet else { return { _ in nil } }
    return { wallet.derivationOfSpk(spk: $0) }
  }

  /// Every output of a PSBT's transaction, classified against the wallet's script index.
  func classifiedOutputs(of psbt: Psbt, network: Network) -> [PSBTOutputInfo] {
    guard let tx = try? psbt.extractTx() else { return [] }
    return PSBTValidator.classifyOutputs(tx: tx, network: network, derivationOf: derivationLookup)
  }

  /// The single change output, if there is one. Deterministically the first — BDK
  /// creates at most one, and a second internal-keychain output is reported as a
  /// recipient rather than silently replacing this one.
  private func changeOutput(of psbt: Psbt, network: Network) -> PSBTOutputInfo? {
    classifiedOutputs(of: psbt, network: network).first { $0.role == .change }
  }

  /// Everything the review screen needs to let a user check the change output: where
  /// the wallet says the address comes from, and whether the PSBT's account of it
  /// stands up.
  ///
  /// The path shown is the wallet's own derivation, not the PSBT's claim — a PSBT can
  /// write any path it likes, so echoing that back would let it dictate the very thing
  /// the user is checking.
  func changeVerification(_ psbtData: Data) -> PSBTChangeVerification? {
    guard let psbt = try? Psbt(psbtBase64: psbtData.base64EncodedString()),
          let tx = try? psbt.extractTx() else { return nil }

    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let truth = psbtGroundTruth
    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: network, derivationOf: derivationLookup)
    guard let change = outputs.first(where: { $0.role == .change }) else { return nil }

    let path = change.derivation.flatMap {
      PSBTValidator.derivationPathDescription(
        accountOrigin: truth.accountOrigin,
        keychain: $0.keychain,
        index: $0.index,
      )
    }

    let psbtOutputs = psbt.output()
    let txOutputs = tx.output()
    var status = PSBTChangeVerification.Status.verified
    if change.index < psbtOutputs.count, change.index < txOutputs.count,
       let finding = PSBTValidator.verifyOutputDerivation(
         output: change,
         script: txOutputs[change.index].scriptPubkey,
         derivations: psbtOutputs[change.index].bip32Derivation,
         against: truth,
       )
    {
      status = finding.severity == .critical ? .failed(finding.message) : .warning(finding.message)
    }

    return PSBTChangeVerification(
      address: change.address,
      amount: change.amount,
      derivationPath: path,
      status: status,
    )
  }

  /// What a PSBT pays, derived from its bytes rather than from stored metadata.
  struct PSBTSummary {
    let fee: UInt64
    let feeRateSatVb: String
    let inputCount: Int
    let changeAmount: UInt64?
    let changeAddress: String?
    let recipients: [SavedRecipient]
  }

  /// Describe a PSBT using wallet knowledge alone.
  ///
  /// Deliberately free of the import-time policy checks in
  /// `validateAndParseImportedPSBT`: a saved RBF bump legitimately spends outputs that
  /// are no longer unspent, so those rules would reject a PSBT this wallet built itself.
  func summarizePSBT(_ psbtData: Data) -> PSBTSummary? {
    guard let psbt = try? Psbt(psbtBase64: psbtData.base64EncodedString()),
          let tx = try? psbt.extractTx() else { return nil }
    return summarize(psbt: psbt, tx: tx)
  }

  private func summarize(psbt: Psbt, tx: Transaction) -> PSBTSummary {
    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let fee = (try? psbt.fee()) ?? 0
    let vsize = tx.vsize()

    var changeAmount: UInt64?
    var changeAddress: String?
    var recipients: [SavedRecipient] = []

    for output in PSBTValidator.classifyOutputs(tx: tx, network: network, derivationOf: derivationLookup) {
      // Only the first internal-keychain output is change. Everything else stays
      // visible as a recipient — including self-sends to our own receive addresses,
      // which must not disappear into a "change" line.
      if output.role == .change, changeAmount == nil {
        changeAmount = output.amount
        changeAddress = output.address
        continue
      }
      if output.role == .change {
        psbtLogger.warning("PSBT has more than one change output; listing \(output.address) as a recipient")
      }
      recipients.append(
        SavedRecipient(address: output.address, amountSats: "\(output.amount)", isSendMax: false, label: ""),
      )
    }

    return PSBTSummary(
      fee: fee,
      feeRateSatVb: "\(vsize > 0 ? max(fee / vsize, 1) : 1)",
      inputCount: psbt.input().count,
      changeAmount: changeAmount,
      changeAddress: changeAddress,
      recipients: recipients,
    )
  }

  // MARK: - PSBT Verification

  /// Everything the checks need to know that does not come from the PSBT: what the
  /// wallet's outputs are worth, the account its keys sit under, whose fingerprints
  /// they carry, and how to derive a script at any claimed path.
  var psbtGroundTruth: PSBTGroundTruth {
    .from(
      utxos: utxos,
      transactions: transactions,
      network: currentProfile?.bitcoinNetwork ?? .testnet4,
      cosignerFingerprints: Set((currentProfile?.cosigners ?? []).map(\.fingerprint)),
      scriptAt: scriptLookup,
    )
  }

  /// Derives the script this wallet produces at a keychain and index, whether or not
  /// that index has been revealed yet. Hardened indexes are rejected before this is
  /// called — they cannot be derived from an xpub.
  private var scriptLookup: (KeychainKind, UInt32) -> Script? {
    guard let wallet else { return { _, _ in nil } }
    return { keychain, index in
      guard index < 0x8000_0000 else { return nil }
      return wallet.peekAddress(keychain: keychain, index: index).address.scriptPubkey()
    }
  }

  /// Check a serialized PSBT — input amounts and output derivation claims — against
  /// wallet state.
  func verifyPSBT(_ psbtData: Data) -> [PSBTFinding] {
    guard let psbt = try? Psbt(psbtBase64: psbtData.base64EncodedString()) else {
      return [.critical(PSBTFinding.Code.psbtUnparseable, "This PSBT could not be read")]
    }
    return verifyPSBT(psbt)
  }

  func verifyPSBT(_ psbt: Psbt) -> [PSBTFinding] {
    guard let tx = try? psbt.extractTx() else {
      return [.critical(
        PSBTFinding.Code.psbtUnextractable,
        "This PSBT's transaction could not be read — an input may be missing its UTXO data, or the fee it implies is impossible",
      )]
    }
    return verifyPSBT(psbt, tx: tx)
  }

  /// Preferred entry point when the caller has already parsed and extracted, so the
  /// PSBT is not decoded twice.
  func verifyPSBT(_ psbt: Psbt, tx: Transaction) -> [PSBTFinding] {
    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let truth = psbtGroundTruth
    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: network, derivationOf: derivationLookup)

    let findings = PSBTValidator.verifyInputAmounts(psbt: psbt, tx: tx, against: truth)
      + PSBTValidator.verifyOutputDerivations(psbt: psbt, tx: tx, outputs: outputs, against: truth)
      + PSBTValidator.verifySignatures(psbt: psbt, tx: tx)

    for finding in findings {
      switch finding.severity {
      case .critical: psbtLogger.error("PSBT verification failed [\(finding.code)]: \(finding.message)")
      case .warning: psbtLogger.warning("PSBT verification warning [\(finding.code)]: \(finding.message)")
      case .info: psbtLogger.info("PSBT verification [\(finding.code)]: \(finding.message)")
      }
    }
    if findings.isEmpty {
      psbtLogger.info("PSBT verification passed: \(tx.input().count) input amount(s) match wallet state")
    }
    return findings
  }

  func broadcastPSBT(_ psbtData: Data) async throws -> String {
    guard let profile = currentProfile else { throw AppError.walletNotLoaded }
    let network = NetworkMonitor.shared.state
    guard !network.isOffline else {
      logger.error("Broadcast not sent: \(network.logDescription)")
      throw AppError.electrumConnectionFailed("\(network.message). The transaction wasn't sent.")
    }

    let (_, tx) = try finalizePSBT(psbtData)
    let config = connectionConfig(for: profile)
    logger.info("Broadcasting finalized tx (\(psbtData.count) byte PSBT) via \(config.url)")

    // A new connection, as a sync opens, so one left idle since the last sync can't
    // hold the broadcast up. Until it's open, nothing has been sent.
    let client: ElectrumClient
    do {
      client = try await Self.openConnection(to: config, until: Self.uptime + Constants.electrumConnectSeconds)
    } catch {
      logger.error("Broadcast not sent, couldn't connect: \(error)")
      throw AppError.electrumConnectionFailed("Couldn't reach \(config.host):\(config.port). The transaction wasn't sent.")
    }

    // The broadcast itself has only the socket timeout and its retry, so the server's
    // answer is never cut off
    do {
      let result = try await Task.detached { [client] in
        try client.transactionBroadcast(tx: tx).description
      }.value
      logger.info("Broadcast succeeded: tx \(result)")
      return result
    } catch {
      logger.error("Broadcast failed: \(error)")
      if BroadcastOutcome.classify(error) == .unknown {
        throw AppError.electrumConnectionFailed(
          "The server didn't answer, so Birch can't tell whether it got the transaction. Broadcasting it again is safe.",
        )
      }
      throw error
    }
  }

  // MARK: - PSBT Import Validation

  struct PSBTImportResult {
    let psbtBytes: Data
    let psbtBase64: String
    let fee: UInt64
    let changeAmount: UInt64?
    let changeAddress: String?
    let inputCount: Int
    let recipients: [SavedRecipient]
    let feeRateSatVb: String
    /// Non-critical findings from verification; criticals throw instead.
    let findings: [PSBTFinding]
  }

  enum PSBTImportError: LocalizedError {
    case walletNotLoaded
    case invalidPSBT
    case inputNotOwned(outpoint: String)
    case inputSpent(outpoint: String)
    case inputFrozen(outpoint: String)
    /// A `PSBTValidator` check contradicted wallet state. Carries the finding's
    /// message so new checks do not each need their own case.
    case verificationFailed(String)

    var errorDescription: String? {
      switch self {
      case .walletNotLoaded: "Wallet not loaded"
      case .invalidPSBT: "Invalid PSBT data"
      case let .inputNotOwned(op): "Input \(op) is not owned by this wallet"
      case let .inputSpent(op): "Input \(op) has already been spent"
      case let .inputFrozen(op): "Input \(op) is frozen"
      case let .verificationFailed(message): message
      }
    }
  }

  func validateAndParseImportedPSBT(_ psbtData: Data, frozenOutpoints: Set<String>) throws -> PSBTImportResult {
    guard let wallet else { throw PSBTImportError.walletNotLoaded }

    // Try parsing as base64 first, then as raw binary
    let psbt: Psbt
    if let base64String = String(data: psbtData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let parsed = try? Psbt(psbtBase64: base64String)
    {
      psbt = parsed
    } else if let parsed = try? Psbt(psbtBase64: psbtData.base64EncodedString()) {
      psbt = parsed
    } else {
      throw PSBTImportError.invalidPSBT
    }

    // Validate inputs
    let currentOutpoints = Set(utxos.map(\.id)) // "txid:vout"
    let psbtInputs = psbt.input()

    guard let tx = try? psbt.extractTx() else {
      throw PSBTImportError.invalidPSBT
    }

    let txInputs = tx.input()

    // 1. Check all inputs are owned by this wallet (via witness_utxo in PSBT inputs)
    for (i, input) in psbtInputs.enumerated() {
      if let witnessUtxo = input.witnessUtxo {
        guard wallet.isMine(script: witnessUtxo.scriptPubkey) else {
          let outpoint = i < txInputs.count
            ? "\(txInputs[i].previousOutput.txid):\(txInputs[i].previousOutput.vout)"
            : "unknown"
          throw PSBTImportError.inputNotOwned(outpoint: outpoint)
        }
      }
    }

    // 2. Check inputs are in UTXO set (not spent) and not frozen
    for txIn in txInputs {
      let outpoint = "\(txIn.previousOutput.txid):\(txIn.previousOutput.vout)"

      guard currentOutpoints.contains(outpoint) else {
        throw PSBTImportError.inputSpent(outpoint: outpoint)
      }

      if frozenOutpoints.contains(outpoint) {
        throw PSBTImportError.inputFrozen(outpoint: outpoint)
      }
    }

    // 3. Cross-check every declared input amount against what the wallet knows those
    // outputs hold. Without this, the fee and amounts below are simply whatever the
    // PSBT claims they are.
    let findings = verifyPSBT(psbt, tx: tx)
    if let critical = findings.criticals.first {
      throw PSBTImportError.verificationFailed(critical.message)
    }

    // Everything the review screen shows is derived here, from the bytes.
    let summary = summarize(psbt: psbt, tx: tx)

    let base64 = psbt.serialize()
    guard let bytes = Data(base64Encoded: base64) else {
      throw PSBTImportError.invalidPSBT
    }

    return PSBTImportResult(
      psbtBytes: bytes,
      psbtBase64: base64,
      fee: summary.fee,
      changeAmount: summary.changeAmount,
      changeAddress: summary.changeAddress,
      inputCount: summary.inputCount,
      recipients: summary.recipients,
      feeRateSatVb: summary.feeRateSatVb,
      findings: findings,
    )
  }

  // MARK: - PSBT Signer Info

  struct PSBTSignerInfo {
    let totalSignatures: Int
    let signerFingerprints: Set<String>
    let cosignerSignStatus: [(label: String, fingerprint: String, hasSigned: Bool)]
  }

  func psbtSignerInfo(_ psbtData: Data) -> PSBTSignerInfo? {
    guard let profile = currentProfile,
          let psbt = try? Psbt(psbtBase64: psbtData.base64EncodedString()) else { return nil }

    let inputs = psbt.input()
    guard !inputs.isEmpty, let tx = try? psbt.extractTx() else { return nil }
    let txInputs = tx.input()
    guard txInputs.count == inputs.count else { return nil }

    // Only count signatures from keys that provably govern the input they sit on, and
    // only read derivation data for those same keys. A PSBT can otherwise carry a
    // signature for any pubkey it invents and inflate the progress shown to the user,
    // which is enough to push the flow to the broadcast step.
    //
    // Each input is judged against its own witness script: cosigners derive a
    // different key per input, so one input's key set says nothing about another's.
    // An input whose script cannot be verified falls back to the PSBT's own word.
    var signerPubkeys: Set<String> = []
    var pubkeyToFingerprint: [String: String] = [:]

    for (index, input) in inputs.enumerated() {
      let verified = PSBTValidator.verifiedPubkeys(input: input, txIn: txInputs[index])

      for pubkey in input.partialSigs.keys where verified?.contains(pubkey.lowercased()) ?? true {
        signerPubkeys.insert(pubkey)
      }

      // The mapping stays the PSBT's assertion: it can relabel which of your own
      // cosigners a key belongs to, but it cannot invent a key that satisfies the
      // script, so it cannot manufacture progress.
      for (pubkey, keySource) in input.bip32Derivation
        where verified?.contains(pubkey.lowercased()) ?? true
      {
        pubkeyToFingerprint[pubkey] = keySource.fingerprint
      }
    }

    // Determine which master fingerprints have signed
    var signerFingerprints: Set<String> = []
    for pubkey in signerPubkeys {
      if let fp = pubkeyToFingerprint[pubkey] {
        signerFingerprints.insert(CosignerInfo.normalizedFingerprint(fp))
      }
    }

    // Match against wallet's cosigners
    let cosigners = profile.cosigners.sorted(by: { $0.orderIndex < $1.orderIndex })
    let cosignerStatus = PSBTValidator.cosignerSignStatus(
      signerFingerprints: signerFingerprints,
      cosigners: cosigners.map { (label: $0.label, fingerprint: $0.fingerprint) },
    )

    return PSBTSignerInfo(
      totalSignatures: signerFingerprints.count,
      signerFingerprints: signerFingerprints,
      cosignerSignStatus: cosignerStatus,
    )
  }

  // MARK: - Descriptor Building

  // Both builders rebuild the key origin as [fp/48'/coinType'/0'/2'] rather than
  // using cosigner.derivationPath. This is safe because Birch only supports
  // account-0 BIP48 keys — every entry point (setup wizard, descriptor import,
  // cosigner editing) validates paths via SetupWizardViewModel.validateDerivationPath,
  // and that a new key sits at that path (depth 4, last step 2') via validateXpub.
  // The builders do not repeat the placement check, so wallets saved before it
  // existed still build.

  /// Normalizes each cosigner xpub to standard xpub/tpub format (BDK descriptor
  /// parser does not accept SLIP132-tagged Vpub/Zpub keys) and sorts by it for BIP67.
  /// Throws when a key is not exactly one extended public key — the key text is
  /// placed in the descriptor, so anything else could add keys the cosigner list
  /// does not show.
  private static func canonicalCosigners(
    _ cosigners: [(xpub: String, fingerprint: String, derivationPath: String)],
    network: BitcoinNetwork,
  ) throws -> [(xpub: String, fingerprint: String, derivationPath: String)] {
    let isTestnet = network != .mainnet

    let normalized = try cosigners.enumerated().map { index, cosigner -> (xpub: String, fingerprint: String, derivationPath: String) in
      guard let xpub = URService.canonicalXpub(cosigner.xpub, isTestnet: isTestnet) else {
        throw AppError.descriptorInvalid("Cosigner key \(index + 1) is not a valid extended public key")
      }
      return (xpub: xpub, fingerprint: cosigner.fingerprint, derivationPath: cosigner.derivationPath)
    }

    return normalized.sorted { $0.xpub < $1.xpub }
  }

  static func buildDescriptor(
    requiredSignatures: Int,
    cosigners: [(xpub: String, fingerprint: String, derivationPath: String)],
    network: BitcoinNetwork,
    isChange: Bool,
  ) throws -> String {
    let chain = isChange ? "1" : "0"
    let coinType = network.coinType

    let sorted = try canonicalCosigners(cosigners, network: network)

    let keys = sorted.map { cosigner in
      "[\(cosigner.fingerprint)/48'/\(coinType)'/0'/2']\(cosigner.xpub)/\(chain)/*"
    }.joined(separator: ",")

    return "wsh(sortedmulti(\(requiredSignatures),\(keys)))"
  }

  /// Build a combined output descriptor with <0;1>/* multipath notation and BIP-380 checksum
  static func buildCombinedDescriptor(
    requiredSignatures: Int,
    cosigners: [(xpub: String, fingerprint: String, derivationPath: String)],
    network: BitcoinNetwork,
  ) throws -> String {
    let coinType = network.coinType

    let sorted = try canonicalCosigners(cosigners, network: network)

    let keys = sorted.map { cosigner in
      "[\(cosigner.fingerprint)/48'/\(coinType)'/0'/2']\(cosigner.xpub)/<0;1>/*"
    }.joined(separator: ",")

    let raw = "wsh(sortedmulti(\(requiredSignatures),\(keys)))"

    return raw + "#" + descriptorChecksum(raw)
  }

  /// Compute the BIP-380 descriptor checksum (8-character string)
  /// Reference: https://github.com/bitcoin/bitcoin/blob/master/src/script/descriptor.cpp
  static func descriptorChecksum(_ descriptor: String) -> String {
    let inputCharset = "0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ "
    let checksumCharset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    var c: UInt64 = 1
    var cls = 0
    var clsCount = 0

    func polyMod(_ c: inout UInt64, _ val: Int) {
      let c0 = Int(c >> 35)
      c = ((c & 0x7_FFFF_FFFF) << 5) ^ UInt64(val)
      if c0 & 1 != 0 {
        c ^= 0xF5_DEE5_1989
      }
      if c0 & 2 != 0 {
        c ^= 0xA9_FDCA_3312
      }
      if c0 & 4 != 0 {
        c ^= 0x1B_AB10_E32D
      }
      if c0 & 8 != 0 {
        c ^= 0x37_06B1_677A
      }
      if c0 & 16 != 0 {
        c ^= 0x64_4D62_6FFD
      }
    }

    for ch in descriptor {
      guard let pos = inputCharset.firstIndex(of: ch) else {
        return ""
      }
      let idx = inputCharset.distance(from: inputCharset.startIndex, to: pos)
      polyMod(&c, idx & 31)
      cls = cls * 3 + (idx >> 5)
      clsCount += 1
      if clsCount == 3 {
        polyMod(&c, cls)
        cls = 0
        clsCount = 0
      }
    }
    if clsCount > 0 {
      polyMod(&c, cls)
    }
    (0 ..< 8).forEach { _ in polyMod(&c, 0) }
    c ^= 1

    let checksumArray = Array(checksumCharset)
    var result = ""
    for j in 0 ..< 8 {
      result.append(checksumArray[Int((c >> (5 * (7 - j))) & 31)])
    }
    return result
  }

  // MARK: - Helpers

  func bdkNetwork(from network: BitcoinNetwork) -> Network {
    switch network {
    case .mainnet: .bitcoin
    case .testnet4: .testnet4
    case .testnet3: .testnet
    case .signet: .signet
    }
  }

  func bdkNetworkKind(from network: BitcoinNetwork) -> NetworkKind {
    switch network {
    case .mainnet: .main
    case .testnet4, .testnet3, .signet: .test
    }
  }
}

// MARK: - Sync Progress Inspector

/// Reports each batch of addresses the full scan starts. BDK calls the inspector
/// once per address as it takes it into a batch request, so the first address of a
/// batch (an index that's a multiple of the batch size) marks the start of that
/// batch and the end of the one before. The time is read here, on BDK's thread,
/// so a busy main thread doesn't delay it.
final class FullScanProgressInspector: FullScanScriptInspector, @unchecked Sendable {
  private let batchSize: UInt32
  private let onBatchStart: (KeychainKind, UInt32, TimeInterval) -> Void

  init(batchSize: UInt32, onBatchStart: @escaping (KeychainKind, UInt32, TimeInterval) -> Void) {
    self.batchSize = max(batchSize, 1)
    self.onBatchStart = onBatchStart
  }

  func inspect(keychain: KeychainKind, index: UInt32, script _: Script) {
    guard index % batchSize == 0 else { return }
    let time = ProcessInfo.processInfo.systemUptime
    DispatchQueue.main.async { [onBatchStart] in
      onBatchStart(keychain, index, time)
    }
  }
}

// MARK: - Broadcast Outcome

/// What a failed broadcast means for the transaction
enum BroadcastOutcome: Equatable {
  /// The server answered and refused it
  case rejected
  /// The connection failed after the transaction went out, so the server may have it
  case unknown
  /// Any other failure, shown as it is
  case other

  static func classify(_ error: Error) -> BroadcastOutcome {
    guard let error = error as? ElectrumError else { return .other }
    return switch error {
    case .Protocol: .rejected
    case .IoError, .SharedIoError, .AllAttemptsErrored, .CouldntLockReader, .Mpsc: .unknown
    default: .other
    }
  }
}

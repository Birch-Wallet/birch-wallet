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
  private(set) var requiredSignatures: Int = 2
  private(set) var totalCosigners: Int = 1
  private(set) var chainTipHeight: UInt32 = 0
  private var needsFullScan: Bool = true
  var syncTask: Task<Void, Error>?

  // Sync state — single source of truth
  private(set) var syncState: WalletSyncState = .notStarted
  private(set) var lastSyncDate: Date?
  private(set) var lastSyncType: SyncType = .none
  private(set) var syncLog: [String] = []

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
    autoSyncCancellable = Timer.publish(every: 1800, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        guard let self, !self.syncState.isSyncing, wallet != nil else { return }
        syncTask = Task {
          try? await self.sync()
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
    if timeSinceLastSync >= 1800 {
      syncTask = Task {
        try? await self.sync()
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

  var electrumURL: String? {
    guard let profile = currentProfile else { return nil }
    return profile.electrumConfig.url
  }

  /// Returns a user-friendly description for Electrum connection errors,
  /// detecting self-signed certificate issues that BDK cannot handle.
  static func friendlyElectrumError(_ error: Error) -> String {
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

  private init() {}

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
    syncState = .notStarted
    lastSyncDate = nil
    syncLog = []
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
        persister: persister
      )
      // Reveal address #0 for both keychains so incremental syncs always cover it.
      // Without this, startSyncWithRevealedSpks() has nothing to sync against on a
      // brand-new wallet, and any funds sent to the first receive address are missed.
      _ = w.revealNextAddress(keychain: .external)
      _ = w.revealNextAddress(keychain: .internal)
      _ = try w.persist(persister: persister)
      addToLog("Revealed address #0 for external and internal keychains")
    }

    // Full scan only if last full scan was over 1 hour ago (or never)
    let fullScanKey = "lastFullScanDate_\(profile.id.uuidString)"
    let lastFullScan = UserDefaults.standard.object(forKey: fullScanKey) as? Date
    let hoursSinceFullScan = lastFullScan.map { Date().timeIntervalSince($0) / 3600 }
    needsFullScan = (hoursSinceFullScan ?? .infinity) >= 1.0
    addToLog("Full scan needed: \(needsFullScan) (last: \(lastFullScan?.description ?? "never"))")
    syncState = .notStarted
    lastSyncType = .none

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

    // Connect to Electrum — may fail offline, but wallet data is still available
    let config = profile.electrumConfig
    addToLog("Connecting to Electrum: \(config.url)")
    do {
      let url = config.url
      let validateDomain = !config.allowInsecureSSL
      electrumClient = try await Task.detached { try ElectrumClient(url: url, validateDomain: validateDomain) }.value
      electrumConnectionError = nil
      addToLog("Electrum client initialized")
    } catch {
      electrumClient = nil
      electrumConnectionError = Self.friendlyElectrumError(error)
      addToLog("Electrum connection failed: \(error)")
    }
  }

  // MARK: - Sync

  func sync() async throws {
    guard let wallet else {
      addToLog("Sync failed: Wallet not loaded")
      throw AppError.walletNotLoaded
    }

    guard !syncState.isSyncing else {
      addToLog("Sync skipped: already in progress")
      return
    }

    // Capture wallet identity and persister at start — if the wallet is switched
    // or reloaded during sync, we must not apply results or persist to the wrong
    // database. The generation (not the profile id) is the identity check, so a
    // same-profile reload also invalidates this sync.
    let syncGeneration = walletGeneration
    let syncProfileId = currentProfile?.id // for per-profile UserDefaults keys only
    let syncPersister = persister

    setSyncState(.syncing("Connecting…"), generation: syncGeneration)
    addToLog("Starting sync (needsFullScan: \(needsFullScan))")

    // Capture pre-sync state so completion can log deltas.
    let syncStartTime = Date()
    let balanceBefore = balance
    let txCountBefore = transactions.count
    let utxoCountBefore = utxos.count

    do {
      // Try to reconnect if client is nil (e.g. app started offline)
      if electrumClient == nil, let profile = currentProfile {
        let config = profile.electrumConfig
        addToLog("Re-initializing Electrum client: \(config.url)")
        let reconnectURL = config.url
        let validateDomain = !config.allowInsecureSSL
        electrumClient = try await Task.detached { try ElectrumClient(url: reconnectURL, validateDomain: validateDomain) }.value
        electrumConnectionError = nil
      }

      guard let client = electrumClient else {
        addToLog("Sync failed: No Electrum client")
        throw AppError.electrumConnectionFailed("No internet connection")
      }

      // Verify server is reachable before starting scan — prevents showing
      // misleading "Scanning addresses" progress when offline / server is down.
      setSyncState(.syncing("Checking server…"), generation: syncGeneration)
      try await Task.detached { try client.ping() }.value
      addToLog("Server ping OK")

      // Fetch chain tip early to confirm server returns real data
      if let header = await Task.detached(operation: { [client] in try? client.blockHeadersSubscribe() }).value {
        guard walletGeneration == syncGeneration else {
          addToLog("Sync cancelled: wallet replaced during chain tip fetch")
          return
        }
        chainTipHeight = UInt32(header.height)
        if let profileId = syncProfileId {
          UserDefaults.standard.set(Int(chainTipHeight), forKey: "chainTipHeight_\(profileId.uuidString)")
        }
        electrumVerified = true
        electrumConnectionError = nil
        addToLog("Chain tip height: \(chainTipHeight)")
      }

      if needsFullScan {
        let gapLimit = currentProfile?.addressGapLimit ?? Constants.maxAddressGap
        addToLog("Starting full scan (gapLimit: \(gapLimit))")

        let inspector = FullScanProgressInspector { [weak self] keychain, index in
          let path = keychain == .external ? "0" : "1"
          Task { @MainActor [weak self] in
            self?.setSyncState(.syncing("Scanning …/\(path)/\(index)"), generation: syncGeneration)
          }
        }
        let fullScanRequest = try wallet.startFullScan()
          .inspectSpksForAllKeychains(inspector: inspector)
          .build()

        addToLog("Full scan request built")
        setSyncState(.syncing("Scanning addresses…"), generation: syncGeneration)
        let update = try await Task.detached { [client] in
          try client.fullScan(
            request: fullScanRequest,
            stopGap: UInt64(gapLimit),
            batchSize: 50,
            fetchPrevTxouts: true
          )
        }.value

        // Bail out if the wallet was switched or reloaded during the network scan
        guard walletGeneration == syncGeneration else {
          addToLog("Sync cancelled: wallet replaced during full scan")
          return
        }
        try Task.checkCancellation()

        addToLog("Full scan update received from server")
        setSyncState(.syncing("Applying update…"), generation: syncGeneration)
        try wallet.applyUpdate(update: update)
        addToLog("Full scan update applied to wallet")
        needsFullScan = false
        lastSyncType = .fullScan
        if let profileId = syncProfileId {
          UserDefaults.standard.set(Date(), forKey: "lastFullScanDate_\(profileId.uuidString)")
        }
      } else {
        addToLog("Starting incremental sync")

        let inspector = SyncProgressInspector { [weak self] _, total in
          Task { @MainActor [weak self] in
            self?.setSyncState(.syncing("Checking \(total) scripts…"), generation: syncGeneration)
          }
        }
        let syncRequest = try wallet.startSyncWithRevealedSpks()
          .inspectSpks(inspector: inspector)
          .build()

        addToLog("Sync request built")
        setSyncState(.syncing("Refreshing transactions…"), generation: syncGeneration)
        let update = try await Task.detached { [client] in
          try client.sync(
            request: syncRequest,
            batchSize: 50,
            fetchPrevTxouts: true
          )
        }.value

        // Bail out if the wallet was switched or reloaded during the network sync
        guard walletGeneration == syncGeneration else {
          addToLog("Sync cancelled: wallet replaced during incremental sync")
          return
        }
        try Task.checkCancellation()

        addToLog("Sync update received from server")
        setSyncState(.syncing("Applying update…"), generation: syncGeneration)
        try wallet.applyUpdate(update: update)
        addToLog("Sync update applied to wallet")
        lastSyncType = .incremental
      }

      // Final identity check before persisting
      guard walletGeneration == syncGeneration else {
        addToLog("Sync cancelled: wallet replaced before persist")
        return
      }

      setSyncState(.syncing("Saving…"), generation: syncGeneration)
      if let syncPersister {
        addToLog("Persisting wallet state")
        _ = try wallet.persist(persister: syncPersister)
      }

      // Verify wallet identity one more time after final await
      guard walletGeneration == syncGeneration else {
        addToLog("Sync completed but wallet replaced — discarding results")
        return
      }

      updateCachedData()
      pruneStaleeSavedPSBTs()

      let now = Date()
      lastSyncDate = now
      setSyncState(.synced(now), generation: syncGeneration)

      let duration = String(format: "%.1f", now.timeIntervalSince(syncStartTime))
      let balanceDelta = Int64(balance) - Int64(balanceBefore)
      let balanceDeltaStr = balanceDelta >= 0 ? "+\(balanceDelta)" : "\(balanceDelta)"
      addToLog(
        "Sync completed successfully in \(duration)s (\(lastSyncType.description)): "
          + "balance \(balanceBefore) -> \(balance) sats (\(balanceDeltaStr)), "
          + "txs \(txCountBefore) -> \(transactions.count), "
          + "utxos \(utxoCountBefore) -> \(utxos.count), tip \(chainTipHeight)"
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
      addToLog("Sync failed with error: \(errorMsg)")
      let friendly = Self.friendlyElectrumError(error)
      electrumVerified = false
      electrumConnectionError = friendly
      setSyncState(.error(friendly), generation: syncGeneration)
      throw error
    }
  }

  func fullResync() async throws {
    needsFullScan = true
    try await sync()
  }

  /// Tests connectivity by fetching the chain tip from the server.
  /// For SSL connections, validates the certificate first with a native TLS check
  /// to detect self-signed certs before BDK obscures the error.
  /// Returns the block height on success.
  @discardableResult
  func testElectrumConnection(config: ElectrumConfig) async throws -> UInt32 {
    // Pre-check SSL certificate before handing off to BDK
    if config.useSSL, !config.allowInsecureSSL {
      try await Self.validateTLSCertificate(host: config.host, port: config.port)
    }

    let url = config.url
    let validateDomain = !config.allowInsecureSSL
    let header = try await Task.detached {
      let client = try ElectrumClient(url: url, validateDomain: validateDomain)
      return try client.blockHeadersSubscribe()
    }.value
    return UInt32(header.height)
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
    if config.useSSL, !config.allowInsecureSSL {
      try await Self.validateTLSCertificate(host: config.host, port: config.port)
    }

    let url = config.url
    let validateDomain = !config.allowInsecureSSL
    let genesisHeader = try await Task.detached {
      let client = try ElectrumClient(url: url, validateDomain: validateDomain)
      return try client.blockHeader(height: 0)
    }.value

    for (network, nonce) in Self.genesisNonce where genesisHeader.nonce == nonce {
      return network
    }
    return nil
  }

  /// Performs a native TLS handshake to validate the server's certificate.
  /// Throws a clear error if the certificate is self-signed or untrusted.
  private static func validateTLSCertificate(host: String, port: UInt16) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let queue = DispatchQueue(label: "tls-check")
      let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tls
      )

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          connection.cancel()
          continuation.resume()
        case let .waiting(error):
          connection.cancel()
          if case let .tls(osStatus) = error, osStatus == errSecCertificateExpired {
            continuation.resume(throwing: AppError.electrumConnectionFailed(
              "SSL certificate expired on \(host):\(port)."
            ))
          } else {
            continuation.resume(throwing: AppError.electrumConnectionFailed(
              "SSL certificate rejected for \(host):\(port) — the server may use a self-signed certificate. Try using TCP instead of SSL, or use a server with a CA-signed certificate."
            ))
          }
        case let .failed(error):
          connection.cancel()
          let desc = error.localizedDescription
          if desc.contains("certificate") || desc.contains("SSL") || desc.contains("trust") {
            continuation.resume(throwing: AppError.electrumConnectionFailed(
              "SSL certificate rejected for \(host):\(port) — the server may use a self-signed certificate. Try using TCP instead of SSL, or use a server with a CA-signed certificate."
            ))
          } else {
            continuation.resume(throwing: AppError.electrumConnectionFailed(
              "Connection to \(host):\(port) failed: \(desc)"
            ))
          }
        case .cancelled:
          break
        default:
          break
        }
      }

      connection.start(queue: queue)
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
      uniquingKeysWith: { first, _ in first }
    )
    transactions = txList.map { canonicalTx -> TransactionItem in
      let tx = canonicalTx.transaction
      let txid = tx.computeTxid().description

      let sentAndReceived = wallet.sentAndReceived(tx: tx)
      let sent = sentAndReceived.sent.toSat()
      let received = sentAndReceived.received.toSat()

      let isIncoming = received > sent
      let amount: Int64 = isIncoming ? Int64(received - sent) : -Int64(sent - received)

      var confirmations: UInt32 = 0
      var timestamp: Date?
      var blockHeight: UInt32?
      var firstSeen: Date?

      switch canonicalTx.chainPosition {
      case let .confirmed(confirmationBlockTime, _):
        blockHeight = confirmationBlockTime.blockId.height
        if chainTipHeight > 0, let bh = blockHeight {
          confirmations = chainTipHeight >= bh ? chainTipHeight - bh + 1 : 1
        } else {
          confirmations = 1
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
          isMine: mine
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
          isMine: mine
        )
      }

      return TransactionItem(
        id: txid,
        amount: amount,
        fee: feeAmount,
        confirmations: confirmations,
        timestamp: timestamp,
        isIncoming: isIncoming,
        blockHeight: blockHeight,
        vsize: txVsize,
        firstSeen: firstSeen,
        inputs: inputs,
        outputs: outputs
      )
    }.sorted {
      let isUnconfirmed0 = $0.confirmations == 0
      let isUnconfirmed1 = $1.confirmations == 0
      if isUnconfirmed0 != isUnconfirmed1 {
        return isUnconfirmed0
      }
      return ($0.timestamp ?? $0.firstSeen ?? .distantPast) > ($1.timestamp ?? $1.firstSeen ?? .distantPast)
    }

    let unspent = wallet.listUnspent()
    utxos = unspent.map { output in
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
        derivationIndex: output.derivationIndex
      )
    }.sorted { u0, u1 in
      let isUnconfirmed0 = !u0.isConfirmed
      let isUnconfirmed1 = !u1.isConfirmed
      if isUnconfirmed0 != isUnconfirmed1 {
        return isUnconfirmed0
      }
      let tx0 = transactions.first(where: { $0.id == u0.txid })
      let tx1 = transactions.first(where: { $0.id == u1.txid })
      return (tx0?.timestamp ?? tx0?.firstSeen ?? .distantPast) > (tx1?.timestamp ?? tx1?.firstSeen ?? .distantPast)
    }
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

  func getNextAddress() throws -> (String, UInt32) {
    guard let wallet else { throw AppError.walletNotLoaded }
    let usedAddresses = buildUsedAddressSet()
    for i in 0 ..< UInt32(Constants.maxAddressGap) {
      let info = wallet.peekAddress(keychain: .external, index: i)
      if !usedAddresses.contains(info.address.description) {
        // Reveal addresses up to this index so that incremental syncs
        // (startSyncWithRevealedSpks) will monitor it for incoming funds.
        var revealed = wallet.revealNextAddress(keychain: .external)
        while revealed.index < info.index {
          revealed = wallet.revealNextAddress(keychain: .external)
        }
        guard let persister else {
          logger.warning("Address revealed without persister — derivation state may be lost")
          return (info.address.description, info.index)
        }
        _ = try wallet.persist(persister: persister)
        return (info.address.description, info.index)
      }
    }
    // All peeked addresses are used — reveal a new one
    let info = wallet.revealNextAddress(keychain: .external)
    guard let persister else {
      logger.warning("Address revealed without persister — derivation state may be lost")
      return (info.address.description, info.index)
    }
    _ = try wallet.persist(persister: persister)
    return (info.address.description, info.index)
  }

  func revealNextAddress() throws -> (String, UInt32) {
    guard let wallet else { throw AppError.walletNotLoaded }
    let info = wallet.revealNextAddress(keychain: .external)
    guard let persister else {
      logger.warning("Address revealed without persister — derivation state may be lost")
      return (info.address.description, info.index)
    }
    _ = try wallet.persist(persister: persister)
    return (info.address.description, info.index)
  }

  func getAddresses(keychain: UTXOItem.KeychainKind) -> [AddressItem] {
    guard let wallet else { return [] }
    let bdkKeychain: KeychainKind = keychain == .external ? .external : .internal
    let usedAddresses = buildUsedAddressSet()
    let gapLimit = currentProfile?.addressGapLimit ?? Constants.maxAddressGap

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
        isChange: keychain == .internal
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
  }

  /// Fetches estimated fee rates in sats/vB, dispatching to the selected source
  func getFeeRates() async throws -> RecommendedFees {
    let sourceRaw = UserDefaults.standard.string(forKey: Constants.feeSourceKey) ?? FeeSource.electrum.rawValue
    let source = FeeSource(rawValue: sourceRaw) ?? .electrum

    do {
      let fees: RecommendedFees = switch source {
      case .mempoolSpace:
        try await fetchMempoolFees()
      case .electrum:
        try await fetchElectrumFees()
      case .fixed:
        RecommendedFees(fast: 5.0, medium: 2.0, slow: 1.0)
      }
      logger.info(
        "Fee estimates from \(source.rawValue): fast \(fees.fast), medium \(fees.medium), slow \(fees.slow) sat/vB"
      )
      return fees
    } catch {
      logger.error("Fee estimation from \(source.rawValue) failed: \(error)")
      throw error
    }
  }

  private func fetchMempoolFees() async throws -> RecommendedFees {
    let base = switch currentProfile?.bitcoinNetwork {
    case .mainnet: "https://mempool.space"
    case .testnet4: "https://mempool.space/testnet4"
    case .testnet3: "https://mempool.space/testnet"
    case .signet: "https://mempool.space/signet"
    case nil: "https://mempool.space"
    }
    let url = URL(string: "\(base)/api/v1/fees/precise")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let decoded = try JSONDecoder().decode(MempoolPreciseFees.self, from: data)
    return RecommendedFees(
      fast: decoded.fastestFee,
      medium: decoded.halfHourFee,
      slow: decoded.economyFee
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
    guard let electrumClient else {
      throw AppError.electrumConnectionFailed("Not connected to server")
    }

    // Electrum returns BTC/kB. To convert to sats/vB:
    // BTC -> sats = * 100,000,000
    // kB -> vB = / 1000
    // So multiplier is 100,000
    let multiplier: Double = 100_000

    return await Task.detached {
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
        slow: slow
      )
    }.value
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

  func createPSBT(
    recipients: [(address: String, amount: UInt64, isSendMax: Bool)],
    feeRate: Double,
    utxos: [(txid: String, vout: UInt32)]? = nil,
    unspendable: Set<String> = []
  ) async throws -> PSBTResult {
    guard let wallet else { throw AppError.walletNotLoaded }

    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let satKwu = max(UInt64(round(feeRate * 250.0)), 1)
    let bdkFeeRate = FeeRate.fromSatPerKwu(satKwu: satKwu)

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
        + "fee \(fee) sats @ \(feeRate) sat/vB\(changeAddress.map { ", change \(changeAmount ?? 0) sats to \($0)" } ?? "")"
    )
    return PSBTResult(base64: base64, bytes: bytes, fee: fee, changeAmount: changeAmount, changeAddress: changeAddress, inputCount: inputCount)
  }

  func createBumpFeePSBT(txid: String, feeRate: Double) async throws -> PSBTResult {
    guard let wallet else { throw AppError.walletNotLoaded }

    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let satKwu = max(UInt64(round(feeRate * 250.0)), 1)
    let bdkFeeRate = FeeRate.fromSatPerKwu(satKwu: satKwu)

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

  /// Resolves a script to the keychain the wallet derived it from, or nil if the
  /// wallet has no record of it. Backs every output classification.
  private var keychainLookup: (Script) -> KeychainKind? {
    guard let wallet else { return { _ in nil } }
    return { wallet.derivationOfSpk(spk: $0)?.keychain }
  }

  /// Every output of a PSBT's transaction, classified against the wallet's script index.
  func classifiedOutputs(of psbt: Psbt, network: Network) -> [PSBTOutputInfo] {
    guard let tx = try? psbt.extractTx() else { return [] }
    return PSBTValidator.classifyOutputs(tx: tx, network: network, keychainOf: keychainLookup)
  }

  /// The single change output, if there is one. Deterministically the first — BDK
  /// creates at most one, and a second internal-keychain output is reported as a
  /// recipient rather than silently replacing this one.
  private func changeOutput(of psbt: Psbt, network: Network) -> PSBTOutputInfo? {
    classifiedOutputs(of: psbt, network: network).first { $0.role == .change }
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

    for output in PSBTValidator.classifyOutputs(tx: tx, network: network, keychainOf: keychainLookup) {
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
        SavedRecipient(address: output.address, amountSats: "\(output.amount)", isSendMax: false, label: "")
      )
    }

    return PSBTSummary(
      fee: fee,
      feeRateSatVb: "\(vsize > 0 ? max(fee / vsize, 1) : 1)",
      inputCount: psbt.input().count,
      changeAmount: changeAmount,
      changeAddress: changeAddress,
      recipients: recipients
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
      scriptAt: scriptLookup
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
        "This PSBT's transaction could not be read — an input may be missing its UTXO data, or the fee it implies is impossible"
      )]
    }
    return verifyPSBT(psbt, tx: tx)
  }

  /// Preferred entry point when the caller has already parsed and extracted, so the
  /// PSBT is not decoded twice.
  func verifyPSBT(_ psbt: Psbt, tx: Transaction) -> [PSBTFinding] {
    let network = bdkNetwork(from: currentProfile?.bitcoinNetwork ?? .testnet4)
    let truth = psbtGroundTruth
    let outputs = PSBTValidator.classifyOutputs(tx: tx, network: network, keychainOf: keychainLookup)

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
    guard let client = electrumClient else {
      logger.error("Broadcast failed: not connected to Electrum server")
      throw AppError.electrumConnectionFailed("Not connected to server")
    }

    let (_, tx) = try finalizePSBT(psbtData)
    logger.info("Broadcasting finalized tx (\(psbtData.count) byte PSBT) via \(currentProfile?.electrumConfig.url ?? "unknown")")
    do {
      let result = try await Task.detached { [client] in
        try client.transactionBroadcast(tx: tx).description
      }.value
      logger.info("Broadcast succeeded: tx \(result)")
      return result
    } catch {
      logger.error("Broadcast failed: \(error)")
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
      findings: findings
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
      cosigners: cosigners.map { (label: $0.label, fingerprint: $0.fingerprint) }
    )

    return PSBTSignerInfo(
      totalSignatures: signerFingerprints.count,
      signerFingerprints: signerFingerprints,
      cosignerSignStatus: cosignerStatus
    )
  }

  // MARK: - Descriptor Building

  // Both builders rebuild the key origin as [fp/48'/coinType'/0'/2'] rather than
  // using cosigner.derivationPath. This is safe because Birch only supports
  // account-0 BIP48 keys — every entry point (setup wizard, descriptor import,
  // cosigner editing) validates paths via SetupWizardViewModel.validateDerivationPath.

  static func buildDescriptor(
    requiredSignatures: Int,
    cosigners: [(xpub: String, fingerprint: String, derivationPath: String)],
    network: BitcoinNetwork,
    isChange: Bool
  ) -> String {
    let chain = isChange ? "1" : "0"
    let coinType = network.coinType
    let isTestnet = network != .mainnet

    let normalized = cosigners.map { cosigner -> (xpub: String, fingerprint: String, derivationPath: String) in
      let raw = cosigner.xpub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let xpub = URService.normalizeXpub(raw, isTestnet: isTestnet) ?? raw
      return (xpub: xpub, fingerprint: cosigner.fingerprint, derivationPath: cosigner.derivationPath)
    }

    let sorted = normalized.sorted { $0.xpub < $1.xpub }

    let keys = sorted.map { cosigner in
      "[\(cosigner.fingerprint)/48'/\(coinType)'/0'/2']\(cosigner.xpub)/\(chain)/*"
    }.joined(separator: ",")

    return "wsh(sortedmulti(\(requiredSignatures),\(keys)))"
  }

  /// Build a combined output descriptor with <0;1>/* multipath notation and BIP-380 checksum
  static func buildCombinedDescriptor(
    requiredSignatures: Int,
    cosigners: [(xpub: String, fingerprint: String, derivationPath: String)],
    network: BitcoinNetwork
  ) -> String {
    let coinType = network.coinType
    let isTestnet = network != .mainnet

    // Normalize each cosigner xpub to standard xpub/tpub format (BDK descriptor
    // parser does not accept SLIP132-tagged Vpub/Zpub/Ypub/Upub keys).
    let normalized = cosigners.map { cosigner -> (xpub: String, fingerprint: String, derivationPath: String) in
      let raw = cosigner.xpub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      let xpub = URService.normalizeXpub(raw, isTestnet: isTestnet) ?? raw
      return (xpub: xpub, fingerprint: cosigner.fingerprint, derivationPath: cosigner.derivationPath)
    }

    let sorted = normalized.sorted { $0.xpub < $1.xpub }

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

// MARK: - Sync Progress Inspectors

/// Reports per-script progress during full scan (keychain + derivation index)
final class FullScanProgressInspector: FullScanScriptInspector, @unchecked Sendable {
  private let onProgress: (KeychainKind, UInt32) -> Void

  init(onProgress: @escaping (KeychainKind, UInt32) -> Void) {
    self.onProgress = onProgress
  }

  func inspect(keychain: KeychainKind, index: UInt32, script _: Script) {
    DispatchQueue.main.async { [onProgress] in
      onProgress(keychain, index)
    }
  }
}

/// Reports per-script progress during incremental sync (script + total count)
final class SyncProgressInspector: SyncScriptInspector, @unchecked Sendable {
  private let onProgress: (Script, UInt64) -> Void

  init(onProgress: @escaping (Script, UInt64) -> Void) {
    self.onProgress = onProgress
  }

  func inspect(script: Script, total: UInt64) {
    DispatchQueue.main.async { [onProgress] in
      onProgress(script, total)
    }
  }
}

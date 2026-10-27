import Foundation

/// What a sync is doing, in the words the status row uses.
enum SyncPhase: Equatable {
  case connecting
  case fetching
  case saving

  var label: String {
    switch self {
    case .connecting: "Connecting…"
    case .fetching: "Fetching transactions"
    case .saving: "Saving…"
    }
  }

  /// The label, with the percent while transactions are fetched against a likely
  /// total. A wallet's first sync has no total, so it shows no percent.
  func statusText(progress: Double?) -> String {
    guard self == .fetching, let progress else { return label }
    return "\(label) · \(Int(progress * 100))%"
  }
}

// MARK: - Expected work

/// The work a sync is expected to do, counted in round trips to the Electrum
/// server, from what the saved wallet held when the sync started.
///
/// BDK's full scan asks for the addresses' histories in batches, one round trip a
/// batch, and fetches each transaction it hasn't seen on its own, one round trip
/// each, before it starts the next batch. After the last batch it fetches the
/// confirmations' proofs and headers in two batched calls. The client keeps every
/// transaction it fetched, so another sync on the same connection costs little
/// more than its batches. Birch scans with fetchPrevTxouts off and downloads the
/// few parents the wallet is missing afterwards, so they aren't part of the plan.
struct SyncWorkPlan: Equatable {
  typealias Keychain = UTXOItem.KeychainKind

  struct Batch: Equatable {
    let keychain: Keychain
    let firstIndex: UInt32
    var units: Double
    /// The saved transactions this batch's histories bring in first
    var transactions = 0
    /// False for a batch the scan reached beyond what the saved wallet predicted
    var predicted = true
  }

  /// Connecting, the ping and the chain tip
  static let headUnits = 3.0
  /// The confirmations' proofs and headers, two batched calls after the last batch
  static let tailBaseUnits = 2.0
  /// A transaction the client already fetched this session comes from its cache
  static let cachedTransactionUnits = 0.05

  let batchSize: UInt32
  private(set) var batches: [Batch]
  let tailUnits: Double
  /// The connection already synced this wallet, so its cache holds the transactions
  let clientWarm: Bool

  var scanUnits: Double {
    batches.reduce(0) { $0 + $1.units } + tailUnits
  }

  var totalUnits: Double {
    Self.headUnits + scanUnits
  }

  /// - Parameters:
  ///   - lastUsed: the highest index each keychain has used. The scan goes on until
  ///     `gap` unused addresses in a row follow it.
  ///   - firstSeen: for each saved transaction, the first of the wallet's addresses
  ///     it touches in scan order (receive before change, then by index). That is the
  ///     batch whose histories bring it in; later batches find it in the cache.
  ///   - clientWarm: the connection already synced this wallet, so its cache holds
  ///     the saved transactions.
  static func make(
    lastUsed: [Keychain: UInt32],
    gap: Int,
    batchSize: UInt32,
    firstSeen: [(keychain: Keychain, index: UInt32)],
    clientWarm: Bool,
  ) -> SyncWorkPlan {
    let size = Int(max(batchSize, 1))
    let gap = max(gap, 1)
    var batches: [Batch] = []
    var firstBatch: [Keychain: Int] = [:]
    var batchCount: [Keychain: Int] = [:]
    for keychain in [Keychain.external, .internal] {
      // The scan stops at the gap-th unused address after the last used one
      let scanned = lastUsed[keychain].map { Int($0) + gap + 1 } ?? gap
      let count = (scanned + size - 1) / size
      firstBatch[keychain] = batches.count
      batchCount[keychain] = count
      for i in 0 ..< count {
        batches.append(Batch(keychain: keychain, firstIndex: UInt32(i * size), units: 1))
      }
    }
    let transactionUnits = clientWarm ? cachedTransactionUnits : 1
    for seen in firstSeen {
      guard let first = firstBatch[seen.keychain], let count = batchCount[seen.keychain] else { continue }
      let position = first + min(Int(seen.index) / size, count - 1)
      batches[position].units += transactionUnits
      batches[position].transactions += 1
    }
    return SyncWorkPlan(batchSize: UInt32(size), batches: batches, tailUnits: tailBaseUnits, clientWarm: clientWarm)
  }

  /// The position of the batch that starts at `index`, adding one when the scan
  /// reaches further than the saved wallet did: more addresses were used since. A
  /// batch it adds weighs as much as the average batch.
  mutating func position(keychain: Keychain, index: UInt32) -> Int {
    if let position = batches.firstIndex(where: { $0.keychain == keychain && $0.firstIndex == index }) {
      return position
    }
    let average = batches.isEmpty ? 1 : batches.reduce(0) { $0 + $1.units } / Double(batches.count)
    let position = batches.firstIndex(where: { Self.order($0.keychain) > Self.order(keychain) }) ?? batches.endIndex
    batches.insert(Batch(keychain: keychain, firstIndex: index, units: max(average, 1), predicted: false), at: position)
    return position
  }

  private static func order(_ keychain: Keychain) -> Int {
    keychain == .external ? 0 : 1
  }
}

// MARK: - Progress

/// How far a sync has got, for the hairline under the balance. It moves the way
/// Safari's loading bar does:
/// - It jumps to 10% when the sync starts, so the tap visibly registered.
/// - Each batch BDK starts closes half the distance to the point the work before it
///   ends at.
/// - Between batches it eases toward where the batch in flight should end, at the
///   pace earlier syncs measured, so a slow batch slows the bar instead of stopping
///   it. A slow creep toward the stage's cap keeps it moving once it has caught up.
/// - When the scan reaches further than the saved wallet did, the total grows and
///   the bar slows down. It never moves backward.
/// - It stays under 85% until the scan returns and under 95% until the sync ends,
///   then snaps to full.
///
/// With no plan, a wallet's first sync, there is no total to measure against, so it
/// reports no fraction and the bar sweeps instead.
struct SyncProgressTracker {
  static let start = 0.10
  static let scanEnd = 0.85
  static let cap = 0.95
  /// The share of the remaining distance to a checkpoint that reaching it closes at once
  static let eventStep = 0.5
  /// The easing's time constant, as a share of the expected time of the work in
  /// flight: by then the bar is about 86% of the way to its checkpoint
  static let easeFactor = 0.5
  /// The creep's time constant toward the stage's cap
  static let creepSeconds = 30.0
  /// How long applying and saving the update is expected to take
  static let savingSeconds = 0.3
  /// Seconds per round trip before any sync has measured one
  static let defaultSecondsPerUnit = 0.07

  enum Stage: Equatable {
    case head
    case batch(Int)
    case saving
    case finished
  }

  private(set) var plan: SyncWorkPlan?
  var secondsPerUnit: Double
  private(set) var stage: Stage = .head
  private(set) var display = start
  private var creditedUnits = 0.0
  private var creditedBatches = 0
  private var lastTick: TimeInterval

  init(plan: SyncWorkPlan?, secondsPerUnit: Double, now: TimeInterval) {
    self.plan = plan
    self.secondsPerUnit = secondsPerUnit
    lastTick = now
  }

  /// The bar's fill, or nil while there is no total to fill against
  var fraction: Double? {
    if stage == .finished {
      return 1
    }
    return plan == nil ? nil : display
  }

  /// The server answered the ping and sent its chain tip
  mutating func serverReady(now: TimeInterval) {
    tick(now: now)
    guard stage == .head else { return }
    reach(credit: SyncWorkPlan.headUnits)
    stage = .batch(0)
  }

  /// BDK took the first address of the batch at `index` into a request, so the
  /// batches before it are done
  mutating func batchStarted(keychain: SyncWorkPlan.Keychain, index: UInt32, now: TimeInterval) {
    tick(now: now)
    if stage == .head {
      serverReady(now: now)
    }
    guard case let .batch(current) = stage, var plan else { return }
    let position = plan.position(keychain: keychain, index: index)
    self.plan = plan
    guard position >= current else { return }
    let done = plan.batches[creditedBatches ..< max(position, creditedBatches)].reduce(0) { $0 + $1.units }
    creditedBatches = max(position, creditedBatches)
    stage = .batch(position)
    reach(credit: done)
  }

  /// The full scan returned: every batch, the parents and the proofs are in
  mutating func scanFinished(now: TimeInterval) {
    tick(now: now)
    guard stage != .saving, stage != .finished else { return }
    let remaining = (plan?.totalUnits ?? 0) - creditedUnits
    creditedBatches = plan?.batches.count ?? 0
    stage = .saving
    reach(credit: max(remaining, 0))
  }

  mutating func finish() {
    stage = .finished
    display = 1
  }

  /// Moves the bar on with time: easing toward the next checkpoint, and creeping
  /// toward the stage's cap
  mutating func tick(now: TimeInterval) {
    // An event can carry a time from before the last tick: BDK's thread reads it,
    // and the main thread gets to it after the ticker has run
    let elapsed = now - lastTick
    guard elapsed > 0 else { return }
    lastTick = now
    guard let plan else { return }
    let goal: Double
    let expectedSeconds: Double
    let ceiling: Double
    switch stage {
    case .head:
      goal = target(SyncWorkPlan.headUnits, of: plan)
      expectedSeconds = SyncWorkPlan.headUnits * secondsPerUnit
      ceiling = Self.scanEnd
    case let .batch(position):
      var inFlight = position < plan.batches.count ? plan.batches[position].units : 0
      if position >= plan.batches.count - 1 {
        // After the last batch BDK fetches the parents and the proofs, unannounced
        inFlight += plan.tailUnits
      }
      goal = target(creditedUnits + inFlight, of: plan)
      expectedSeconds = inFlight * secondsPerUnit
      ceiling = Self.scanEnd
    case .saving:
      goal = Self.cap
      expectedSeconds = Self.savingSeconds
      ceiling = Self.cap
    case .finished:
      return
    }
    let tau = max(expectedSeconds * Self.easeFactor, 0.05)
    let eased = goal > display ? display + (goal - display) * (1 - exp(-elapsed / tau)) : display
    let crept = display + (ceiling - display) * (1 - exp(-elapsed / Self.creepSeconds))
    display = min(max(display, eased, crept), ceiling)
  }

  private mutating func reach(credit units: Double) {
    creditedUnits += units
    guard let plan else { return }
    let ceiling = stage == .saving ? Self.cap : Self.scanEnd
    let checkpoint = min(target(creditedUnits, of: plan), ceiling)
    if checkpoint > display {
      display += (checkpoint - display) * Self.eventStep
    }
  }

  /// Where `units` of work done puts the bar: the scan's share of the way from 10% to 85%
  private func target(_ units: Double, of plan: SyncWorkPlan) -> Double {
    let total = plan.totalUnits
    guard total > 0 else { return Self.scanEnd }
    return Self.start + (Self.scanEnd - Self.start) * min(units / total, 1)
  }
}

// MARK: - Actions

/// What a sync is doing now, for the connection sheet's Action row and the debug log
struct SyncAction: Equatable {
  /// The step in technical English, as the Action row shows it
  let description: String
  /// The Electrum calls or BDK work behind it, for the debug log
  let calls: String
  /// When it started, in system uptime
  let startedAt: TimeInterval

  func elapsedSeconds(now: TimeInterval) -> Int {
    max(0, Int(now - startedAt))
  }
}

extension SyncWorkPlan {
  struct BatchCounts: Equatable {
    let receive: Int
    let change: Int

    var total: Int {
      receive + change
    }
  }

  var batchCounts: BatchCounts {
    BatchCounts(
      receive: batches.count(where: { $0.keychain == .external }),
      change: batches.count(where: { $0.keychain == .internal }),
    )
  }

  /// The Action row's words for the batch that starts at `index`, and the Electrum
  /// calls behind it. `scanBatch` is its number across the whole scan, and `planned`
  /// the batches the saved wallet predicted when the sync started, so a scan that
  /// goes further reads "16 of 15+". What BDK downloads after the history request
  /// isn't announced, so it's given as the count the saved wallet suggests: these are
  /// the wallet's own transactions, downloaded again, not new ones.
  func batchAction(keychain: Keychain, index: UInt32, scanBatch: Int, planned: BatchCounts) -> (description: String, calls: String) {
    let size = Int(batchSize)
    let first = Int(index)
    let name = keychain == .external ? "receive" : "change"
    let keychainNumber = first / size + 1
    let keychainPlanned = keychain == .external ? planned.receive : planned.change
    let keychainCount = "\(keychainNumber) of \(keychainPlanned)\(keychainNumber > keychainPlanned ? "+" : "")"
    let pastPlan = batches.count > planned.total || scanBatch > planned.total
    let scanCount = "batch \(scanBatch) of \(planned.total)\(pastPlan ? "+" : "")"
    let request = "Fetching histories for \(name) addresses \(first)–\(first + size - 1) (\(name) \(keychainCount), \(scanCount))"
    let historyCall = "blockchain.scripthash.get_history ×\(size)"

    let position = batches.firstIndex(where: { $0.keychain == keychain && $0.firstIndex == index })
    let batch = position.map { batches[$0] }
    // What the batch downloads after its histories
    var downloads: [String] = []
    var nextCalls: [String] = []
    var cacheNote = ""
    if let batch, !batch.predicted {
      downloads.append("any transactions on them")
      nextCalls.append("blockchain.transaction.get for each one found")
    } else if let batch, batch.transactions > 0 {
      let count = batch.transactions
      if clientWarm {
        cacheNote = "; its \(Self.transactions(count, "known")) \(count == 1 ? "is" : "are") cached on this connection"
      } else {
        downloads.append("about \(Self.transactions(count))")
        nextCalls.append("~\(count) × blockchain.transaction.get (expected)")
      }
    }
    if position == batches.count - 1 {
      // After the last batch BDK fetches the proofs, unannounced
      if clientWarm {
        downloads.append("the latest block headers")
        nextCalls.append("blockchain.block.header for new blocks (batched)")
      } else {
        downloads.append("the confirmation proofs")
        nextCalls.append("blockchain.transaction.get_merkle and blockchain.block.header (batched)")
      }
    }

    let description = request + cacheNote + (downloads.isEmpty ? "" : ", then downloading " + downloads.joined(separator: ", "))
    let calls = historyCall + (nextCalls.isEmpty ? "" : ", then " + nextCalls.joined(separator: ", "))
    return (description, calls)
  }

  /// The same for a first sync, which has no saved wallet to count or expect from
  static func unplannedBatchAction(keychain: Keychain, index: UInt32, batchSize: UInt32, scanBatch: Int) -> (description: String, calls: String) {
    let size = Int(max(batchSize, 1))
    let first = Int(index)
    let name = keychain == .external ? "receive" : "change"
    return (
      "Fetching histories for \(name) addresses \(first)–\(first + size - 1) (\(name) \(first / size + 1), batch \(scanBatch))",
      "blockchain.scripthash.get_history ×\(size), then blockchain.transaction.get for each transaction found",
    )
  }

  private static func transactions(_ count: Int, _ kind: String? = nil) -> String {
    "\(count) \(kind.map { "\($0) " } ?? "")\(count == 1 ? "transaction" : "transactions")"
  }
}

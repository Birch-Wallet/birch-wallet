@testable import birch
import Foundation
import Testing

struct SyncProgressTests {
  // MARK: - Plan

  /// The large testnet4 wallet the sync benchmark used: receive used up to #694 and
  /// change up to #1. BDK asked the server about 750, 750, 800 and 900 addresses at
  /// batch sizes 10, 25, 50 and 100 with a gap of 20, so the plan has to land on the
  /// same batches.
  @Test(arguments: [(10, 750), (25, 750), (50, 800), (100, 900)])
  func `plan has the batches the benchmark scanned`(batchSize: Int, addresses: Int) {
    let plan = SyncWorkPlan.make(
      lastUsed: [.external: 694, .internal: 1],
      gap: 20,
      batchSize: UInt32(batchSize),
      firstSeen: [],
      clientWarm: false,
    )
    #expect(plan.batches.count * batchSize == addresses)
  }

  @Test func `gap 50 adds a batch at most per keychain`() {
    let plan = SyncWorkPlan.make(
      lastUsed: [.external: 694, .internal: 1],
      gap: 50,
      batchSize: 50,
      firstSeen: [],
      clientWarm: false,
    )
    #expect(plan.batches.count(where: { $0.keychain == .external }) == 15)
    #expect(plan.batches.count(where: { $0.keychain == .internal }) == 2)
    #expect(plan.batches.map(\.firstIndex).prefix(3) == [0, 50, 100])
    // Receive is scanned before change
    #expect(plan.batches.firstIndex(where: { $0.keychain == .internal }) == 15)
  }

  @Test func `unused keychains get one batch each`() {
    let plan = SyncWorkPlan.make(lastUsed: [:], gap: 50, batchSize: 50, firstSeen: [], clientWarm: false)
    #expect(plan.batches.map(\.keychain) == [.external, .internal])
    #expect(plan.totalUnits == SyncWorkPlan.headUnits + 2 + SyncWorkPlan.tailBaseUnits)
  }

  @Test func `transactions weigh on the batch that first finds them`() {
    let firstSeen: [(keychain: SyncWorkPlan.Keychain, index: UInt32)] = [(.external, 5), (.external, 49), (.external, 60), (.internal, 0)]
    let cold = SyncWorkPlan.make(
      lastUsed: [.external: 60, .internal: 0],
      gap: 50,
      batchSize: 50,
      firstSeen: firstSeen,
      clientWarm: false,
    )
    #expect(cold.batches.map(\.units) == [3, 2, 1, 2, 1])
    // Parents aren't part of the scan: the app downloads the few missing ones after it
    #expect(cold.tailUnits == SyncWorkPlan.tailBaseUnits)

    // Over a connection that already synced, the transactions are cached
    let warm = SyncWorkPlan.make(
      lastUsed: [.external: 60, .internal: 0],
      gap: 50,
      batchSize: 50,
      firstSeen: firstSeen,
      clientWarm: true,
    )
    #expect(warm.batches[0].units == 1 + 2 * SyncWorkPlan.cachedTransactionUnits)
    #expect(warm.tailUnits == SyncWorkPlan.tailBaseUnits)
  }

  @Test func `a batch past the saved wallet is added before change`() {
    var plan = SyncWorkPlan.make(lastUsed: [.external: 10], gap: 50, batchSize: 50, firstSeen: [], clientWarm: false)
    #expect(plan.batches.count == 3)
    #expect(plan.position(keychain: .external, index: 50) == 1)
    #expect(plan.position(keychain: .external, index: 100) == 2)
    #expect(plan.batches.count == 4)
    #expect(plan.batches[3].keychain == .internal)
  }

  // MARK: - Status text

  @Test func `status shows the percent only while fetching against a total`() {
    #expect(SyncPhase.fetching.statusText(progress: 0.643) == "Fetching transactions · 64%")
    #expect(SyncPhase.fetching.statusText(progress: nil) == "Fetching transactions")
    #expect(SyncPhase.connecting.statusText(progress: 0.5) == "Connecting…")
    #expect(SyncPhase.saving.statusText(progress: 0.9) == "Saving…")
  }

  // MARK: - Tracker

  @Test func `bar starts at 10 percent and ends full`() {
    var tracker = SyncProgressTracker(plan: smallWalletPlan(), secondsPerUnit: 0.065, now: 0)
    #expect(tracker.fraction == SyncProgressTracker.start)
    tracker.finish()
    #expect(tracker.fraction == 1)
  }

  @Test func `first sync has no fraction until it finishes`() {
    var tracker = SyncProgressTracker(plan: nil, secondsPerUnit: 0.065, now: 0)
    #expect(tracker.fraction == nil)
    tracker.serverReady(now: 0.3)
    tracker.batchStarted(keychain: .external, index: 0, now: 0.3)
    tracker.tick(now: 5)
    tracker.scanFinished(now: 10)
    #expect(tracker.fraction == nil)
    tracker.finish()
    #expect(tracker.fraction == 1)
  }

  /// A server that never answers: the bar still moves, so the tap registered, but
  /// five minutes of waiting don't take it past 20%
  @Test(arguments: [true, false])
  func `connecting never passes 20 percent`(large: Bool) throws {
    var tracker = SyncProgressTracker(plan: large ? largeWalletPlan() : smallWalletPlan(), secondsPerUnit: 0.065, now: 0)
    var fills: [Double] = []
    for tenth in 1 ... 3000 {
      tracker.tick(now: Double(tenth) / 10)
      try fills.append(#require(tracker.fraction))
    }
    #expect(fills.allSatisfy { $0 <= SyncProgressTracker.connectingCap })
    #expect(isNonDecreasing(fills))
    #expect(try #require(fills.last) > SyncProgressTracker.start)
  }

  @Test func `the bar passes 20 percent once the server answers`() throws {
    var tracker = SyncProgressTracker(plan: largeWalletPlan(), secondsPerUnit: 0.065, now: 0)
    tracker.tick(now: 60)
    tracker.serverReady(now: 60)
    tracker.tick(now: 90)
    #expect(try #require(tracker.fraction) > SyncProgressTracker.connectingCap)
  }

  /// The large wallet's sync, paced as the benchmark measured it (about 65 ms a round
  /// trip). The bar should be most of the way, but not past 85%, when the scan returns.
  @Test func `large wallet lands between 70 and 85 percent before the scan returns`() {
    let result = replay(largeWalletPlan(), expectedSecondsPerUnit: 0.065, actualSecondsPerUnit: 0.065)
    #expect(result.beforeScanReturns >= 0.70)
    #expect(result.beforeScanReturns <= SyncProgressTracker.scanEnd)
    #expect(isNonDecreasing(result.fills))
    #expect(result.fills.last == 1)
  }

  /// The small wallet has few batches, so most of its bar is the easing between them
  @Test func `small wallet lands between 70 and 85 percent before the scan returns`() {
    let result = replay(smallWalletPlan(), expectedSecondsPerUnit: 0.065, actualSecondsPerUnit: 0.065)
    #expect(result.beforeScanReturns >= 0.70)
    #expect(result.beforeScanReturns <= SyncProgressTracker.scanEnd)
    #expect(isNonDecreasing(result.fills))
  }

  /// A server twice as slow as the wallet's last sync slows the bar down; it doesn't
  /// run ahead of the work
  @Test func `slow server never passes the caps`() {
    let result = replay(largeWalletPlan(), expectedSecondsPerUnit: 0.065, actualSecondsPerUnit: 0.13)
    #expect(isNonDecreasing(result.fills))
    #expect(result.scanFills.allSatisfy { $0 <= SyncProgressTracker.scanEnd })
    #expect(result.savingFills.allSatisfy { $0 <= SyncProgressTracker.cap })
  }

  @Test func `more used addresses grow the total without moving the bar back`() throws {
    let plan = SyncWorkPlan.make(lastUsed: [.external: 100], gap: 50, batchSize: 50, firstSeen: [], clientWarm: false)
    var tracker = SyncProgressTracker(plan: plan, secondsPerUnit: 0.065, now: 0)
    var fills: [Double] = []
    var now = 0.0
    tracker.serverReady(now: 0.2)
    // The saved wallet expects receive batches up to #150; the scan finds two more
    for index: UInt32 in [0, 50, 100, 150, 200, 250] {
      now += 0.5
      tracker.batchStarted(keychain: .external, index: index, now: now)
      try fills.append(#require(tracker.fraction))
    }
    now += 0.5
    tracker.batchStarted(keychain: .internal, index: 0, now: now)
    try fills.append(#require(tracker.fraction))
    #expect(tracker.plan?.batches.count == plan.batches.count + 2)
    #expect(isNonDecreasing(fills))
    #expect(fills.allSatisfy { $0 <= SyncProgressTracker.scanEnd })
  }

  @Test func `an earlier batch arriving late is ignored`() {
    var tracker = SyncProgressTracker(plan: largeWalletPlan(), secondsPerUnit: 0.065, now: 0)
    tracker.serverReady(now: 0.2)
    tracker.batchStarted(keychain: .external, index: 100, now: 1)
    let fill = tracker.fraction
    tracker.batchStarted(keychain: .external, index: 50, now: 0.9)
    #expect(tracker.fraction == fill)
    #expect(tracker.stage == .batch(2))
  }

  // MARK: - Actions

  /// Receive used up to #60 and change up to #0: three receive batches and two change
  private func actionPlan(clientWarm: Bool) -> SyncWorkPlan {
    SyncWorkPlan.make(
      lastUsed: [.external: 60, .internal: 0],
      gap: 50,
      batchSize: 50,
      firstSeen: [(.external, 5), (.external, 49), (.external, 60), (.internal, 0)],
      clientWarm: clientWarm,
    )
  }

  /// The count is the wallet's own transactions on those addresses, downloaded again,
  /// so it mustn't read as new ones arriving
  @Test func `a batch names its addresses, its place and the transactions it downloads`() {
    let plan = actionPlan(clientWarm: false)
    let planned = plan.batchCounts
    #expect(planned == SyncWorkPlan.BatchCounts(receive: 3, change: 2))

    let first = plan.batchAction(keychain: .external, index: 0, scanBatch: 1, planned: planned)
    #expect(first.description == "Fetching histories for receive addresses 0–49 (receive 1 of 3, batch 1 of 5), then downloading about 2 transactions")
    #expect(first.calls == "blockchain.scripthash.get_history ×50, then ~2 × blockchain.transaction.get (expected)")

    let one = plan.batchAction(keychain: .external, index: 50, scanBatch: 2, planned: planned)
    #expect(one.description == "Fetching histories for receive addresses 50–99 (receive 2 of 3, batch 2 of 5), then downloading about 1 transaction")

    let empty = plan.batchAction(keychain: .external, index: 100, scanBatch: 3, planned: planned)
    #expect(empty.description == "Fetching histories for receive addresses 100–149 (receive 3 of 3, batch 3 of 5)")
    #expect(empty.calls == "blockchain.scripthash.get_history ×50")
  }

  /// After the last batch BDK fetches the confirmations' proofs without saying so, so
  /// the last batch's action names them
  @Test func `the last batch names the proofs that follow it`() {
    let plan = actionPlan(clientWarm: false)
    let last = plan.batchAction(keychain: .internal, index: 50, scanBatch: 5, planned: plan.batchCounts)
    #expect(last.description == "Fetching histories for change addresses 50–99 (change 2 of 2, batch 5 of 5), then downloading the confirmation proofs")
    #expect(last.calls == "blockchain.scripthash.get_history ×50, then blockchain.transaction.get_merkle and blockchain.block.header (batched)")
  }

  @Test func `a scan past the saved wallet counts on with a plus`() {
    var plan = SyncWorkPlan.make(lastUsed: [.external: 10], gap: 50, batchSize: 50, firstSeen: [], clientWarm: false)
    let planned = plan.batchCounts
    _ = plan.position(keychain: .external, index: 100)

    let past = plan.batchAction(keychain: .external, index: 100, scanBatch: 3, planned: planned)
    #expect(past.description == "Fetching histories for receive addresses 100–149 (receive 3 of 2+, batch 3 of 3+), then downloading any transactions on them")
    #expect(past.calls == "blockchain.scripthash.get_history ×50, then blockchain.transaction.get for each one found")

    let change = plan.batchAction(keychain: .internal, index: 0, scanBatch: 4, planned: planned)
    #expect(change.description == "Fetching histories for change addresses 0–49 (change 1 of 1, batch 4 of 3+), then downloading the confirmation proofs")
  }

  @Test func `a warm connection's batches say their transactions are cached`() {
    let plan = actionPlan(clientWarm: true)
    let first = plan.batchAction(keychain: .external, index: 0, scanBatch: 1, planned: plan.batchCounts)
    #expect(first.description == "Fetching histories for receive addresses 0–49 (receive 1 of 3, batch 1 of 5); its 2 known transactions are cached on this connection")
    let last = plan.batchAction(keychain: .internal, index: 50, scanBatch: 5, planned: plan.batchCounts)
    #expect(last.description == "Fetching histories for change addresses 50–99 (change 2 of 2, batch 5 of 5), then downloading the latest block headers")
  }

  @Test func `a first sync's batches have no totals or expected counts`() {
    let action = SyncWorkPlan.unplannedBatchAction(keychain: .external, index: 100, batchSize: 50, scanBatch: 3)
    #expect(action.description == "Fetching histories for receive addresses 100–149 (receive 3, batch 3)")
    #expect(action.calls == "blockchain.scripthash.get_history ×50, then blockchain.transaction.get for each transaction found")
  }

  @Test func `an action's timer counts whole seconds`() {
    let action = SyncAction(description: "Checking that the server answers", calls: "server.ping", startedAt: 100)
    #expect(action.elapsedSeconds(now: 100.4) == 0)
    #expect(action.elapsedSeconds(now: 103.9) == 3)
    #expect(action.elapsedSeconds(now: 99) == 0)
  }

  // MARK: - Sync on open

  /// Opening a wallet (a cold start or a switch) skips its sync within 30 minutes of
  /// the last one, the same interval as the auto-sync timer
  @Test func `opening a wallet synced in the last 30 minutes skips the sync`() {
    let now = Date()
    #expect(BitcoinService.syncedRecently(lastSync: now.addingTimeInterval(-60), now: now, hasSynced: true))
    #expect(BitcoinService.syncedRecently(lastSync: now.addingTimeInterval(-29 * 60), now: now, hasSynced: true))
    #expect(!BitcoinService.syncedRecently(lastSync: now.addingTimeInterval(-30 * 60), now: now, hasSynced: true))
    #expect(!BitcoinService.syncedRecently(lastSync: nil, now: now, hasSynced: true))
  }

  /// A database that has never synced (a new wallet, or one rebuilt after a cosigner
  /// edit) syncs whatever the stored date says, and so does a date in the future
  /// (the clock was moved back)
  @Test func `a wallet that never synced always syncs on open`() {
    let now = Date()
    #expect(!BitcoinService.syncedRecently(lastSync: now.addingTimeInterval(-60), now: now, hasSynced: false))
    #expect(!BitcoinService.syncedRecently(lastSync: now.addingTimeInterval(600), now: now, hasSynced: true))
  }

  // MARK: - Helpers

  /// 622 transactions spread over receive #0–#694, change used up to #1, gap 50
  private func largeWalletPlan() -> SyncWorkPlan {
    let firstSeen = (0 ..< 622).map { (keychain: SyncWorkPlan.Keychain.external, index: UInt32($0 * 694 / 621)) }
    return SyncWorkPlan.make(
      lastUsed: [.external: 694, .internal: 1],
      gap: 50,
      batchSize: 50,
      firstSeen: firstSeen,
      clientWarm: false,
    )
  }

  /// 10 transactions on receive #0–#2 and change #0–#8, gap 50
  private func smallWalletPlan() -> SyncWorkPlan {
    let firstSeen: [(keychain: SyncWorkPlan.Keychain, index: UInt32)] = [
      (.external, 0), (.external, 1), (.external, 2), (.external, 2),
      (.internal, 0), (.internal, 2), (.internal, 4), (.internal, 5), (.internal, 7), (.internal, 8),
    ]
    return SyncWorkPlan.make(
      lastUsed: [.external: 2, .internal: 8],
      gap: 50,
      batchSize: 50,
      firstSeen: firstSeen,
      clientWarm: false,
    )
  }

  private struct Replay {
    var fills: [Double] = []
    var scanFills: [Double] = []
    var savingFills: [Double] = []
    var beforeScanReturns = 0.0
  }

  /// Plays a sync through the tracker the way BDK paces one: each batch takes its
  /// units' worth of round trips at `actualSecondsPerUnit`, the proofs
  /// follow the last batch unannounced, and the bar is ticked every 0.1 s.
  private func replay(_ plan: SyncWorkPlan, expectedSecondsPerUnit: Double, actualSecondsPerUnit: Double) -> Replay {
    var tracker = SyncProgressTracker(plan: plan, secondsPerUnit: expectedSecondsPerUnit, now: 0)
    var result = Replay(fills: [tracker.fraction!])
    var now = 0.0
    var saving = false
    func record() {
      let fill = tracker.fraction!
      result.fills.append(fill)
      if saving {
        result.savingFills.append(fill)
      } else {
        result.scanFills.append(fill)
      }
    }
    func advance(by seconds: Double) {
      let end = now + seconds
      while now + 0.1 < end {
        now += 0.1
        tracker.tick(now: now)
        record()
      }
      now = end
    }

    advance(by: SyncWorkPlan.headUnits * actualSecondsPerUnit)
    tracker.serverReady(now: now)
    record()
    for (position, batch) in plan.batches.enumerated() {
      tracker.batchStarted(keychain: batch.keychain, index: batch.firstIndex, now: now)
      record()
      var seconds = batch.units * actualSecondsPerUnit
      if position == plan.batches.count - 1 {
        seconds += plan.tailUnits * actualSecondsPerUnit
      }
      advance(by: seconds)
    }
    tracker.tick(now: now)
    record()
    result.beforeScanReturns = tracker.fraction!
    tracker.scanFinished(now: now)
    saving = true
    record()
    advance(by: SyncProgressTracker.savingSeconds)
    tracker.finish()
    result.fills.append(tracker.fraction!)
    return result
  }

  private func isNonDecreasing(_ fills: [Double]) -> Bool {
    zip(fills, fills.dropFirst()).allSatisfy { $0 <= $1 }
  }
}

@testable import birch
import Foundation
import Testing

struct ResumePSBTPromptTests {
  private static let walletID = UUID()
  private static let now = Date(timeIntervalSince1970: 1_790_000_000)

  private static func makePSBT(walletID: UUID = walletID, savedAgo: TimeInterval) -> SavedPSBT {
    let saved = SavedPSBT(
      walletID: walletID,
      name: "Test",
      psbtBytes: Data(),
      psbtBase64: "",
      signaturesCollected: 0,
      requiredSignatures: 2,
      recipientsJSON: Data(),
      feeRateSatVb: "5",
      totalFee: 705,
      changeAmount: nil,
      changeAddress: nil,
      inputCount: 1,
      manualUTXOSelection: false,
      selectedUTXOIds: "",
      inputOutpoints: ""
    )
    saved.updatedAt = now.addingTimeInterval(-savedAgo)
    return saved
  }

  @Test func recentPSBTIsOffered() {
    let saved = Self.makePSBT(savedAgo: 60 * 60)
    #expect(SavedPSBT.resumeCandidate(in: [saved], walletID: Self.walletID, now: Self.now) === saved)
  }

  @Test func psbtJustInsideWindowIsOffered() {
    let saved = Self.makePSBT(savedAgo: SavedPSBT.resumePromptWindow - 60)
    #expect(SavedPSBT.resumeCandidate(in: [saved], walletID: Self.walletID, now: Self.now) === saved)
  }

  @Test func psbtAtOrPastWindowIsNotOffered() {
    let atWindow = Self.makePSBT(savedAgo: SavedPSBT.resumePromptWindow)
    let past = Self.makePSBT(savedAgo: SavedPSBT.resumePromptWindow + 60)
    #expect(SavedPSBT.resumeCandidate(in: [atWindow], walletID: Self.walletID, now: Self.now) == nil)
    #expect(SavedPSBT.resumeCandidate(in: [past], walletID: Self.walletID, now: Self.now) == nil)
  }

  @Test func newestIsChosenRegardlessOfOrder() {
    let older = Self.makePSBT(savedAgo: 5 * 60 * 60)
    let newer = Self.makePSBT(savedAgo: 60)
    #expect(SavedPSBT.resumeCandidate(in: [older, newer], walletID: Self.walletID, now: Self.now) === newer)
  }

  /// Only the most recent PSBT is ever offered — an older one is never promoted.
  @Test func staleNewestDoesNotFallBackToOlder() {
    let stale = Self.makePSBT(savedAgo: 3 * 24 * 60 * 60)
    let older = Self.makePSBT(savedAgo: 4 * 24 * 60 * 60)
    #expect(SavedPSBT.resumeCandidate(in: [stale, older], walletID: Self.walletID, now: Self.now) == nil)
  }

  @Test func otherWalletsPSBTsAreIgnored() {
    let otherWallet = Self.makePSBT(walletID: UUID(), savedAgo: 60)
    let ours = Self.makePSBT(savedAgo: 2 * 60 * 60)
    #expect(SavedPSBT.resumeCandidate(in: [otherWallet], walletID: Self.walletID, now: Self.now) == nil)
    #expect(SavedPSBT.resumeCandidate(in: [otherWallet, ours], walletID: Self.walletID, now: Self.now) === ours)
  }

  @Test func emptyListOffersNothing() {
    #expect(SavedPSBT.resumeCandidate(in: [], walletID: Self.walletID, now: Self.now) == nil)
  }
}

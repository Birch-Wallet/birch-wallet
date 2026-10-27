@testable import birch
import Foundation
import Testing

/// The wallet picker's saved order
@MainActor
struct WalletOrderingTests {
  /// A wallet named `name`, created `minutesAgo` minutes ago, at saved position `sortOrder`
  private func wallet(_ name: String, minutesAgo: Double, sortOrder: Int = 0) -> WalletProfile {
    let profile = WalletProfile(
      name: name,
      requiredSignatures: 2,
      totalCosigners: 3,
      externalDescriptor: "",
      internalDescriptor: "",
    )
    profile.createdAt = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
    profile.sortOrder = sortOrder
    return profile
  }

  private func names(_ wallets: [WalletProfile]) -> [String] {
    WalletOrdering.sorted(wallets).map(\.name)
  }

  @Test func `wallets saved before ordering line up oldest first`() {
    let wallets = [wallet("New", minutesAgo: 1), wallet("Old", minutesAgo: 30), wallet("Middle", minutesAgo: 10)]
    #expect(WalletOrdering.normalize(wallets))
    #expect(names(wallets) == ["Old", "Middle", "New"])
    #expect(WalletOrdering.sorted(wallets).map(\.sortOrder) == [0, 1, 2])
  }

  @Test func `a saved order is kept and renumbering it changes nothing`() {
    let wallets = [
      wallet("A", minutesAgo: 30, sortOrder: 2),
      wallet("B", minutesAgo: 20, sortOrder: 0),
      wallet("C", minutesAgo: 10, sortOrder: 1),
    ]
    #expect(!WalletOrdering.normalize(wallets))
    #expect(names(wallets) == ["B", "C", "A"])
  }

  @Test func `renumbering closes the gap a deleted wallet leaves`() {
    let wallets = [wallet("A", minutesAgo: 30, sortOrder: 0), wallet("C", minutesAgo: 10, sortOrder: 2)]
    #expect(WalletOrdering.normalize(wallets))
    #expect(WalletOrdering.sorted(wallets).map(\.sortOrder) == [0, 1])
  }

  @Test func `a new wallet goes to the bottom`() {
    let wallets = [wallet("A", minutesAgo: 30, sortOrder: 0), wallet("B", minutesAgo: 20, sortOrder: 4)]
    #expect(WalletOrdering.nextSortOrder(after: wallets) == 5)
    #expect(WalletOrdering.nextSortOrder(after: []) == 0)
  }

  @Test func `moving a wallet down`() {
    let wallets = [
      wallet("A", minutesAgo: 30, sortOrder: 0),
      wallet("B", minutesAgo: 20, sortOrder: 1),
      wallet("C", minutesAgo: 10, sortOrder: 2),
    ]
    // List reports a drag of A to below C as offset 0 to 3
    WalletOrdering.move(wallets, fromOffsets: [0], toOffset: 3)
    #expect(names(wallets) == ["B", "C", "A"])
    #expect(WalletOrdering.sorted(wallets).map(\.sortOrder) == [0, 1, 2])
  }

  @Test func `moving a wallet up`() {
    let wallets = [
      wallet("A", minutesAgo: 30, sortOrder: 0),
      wallet("B", minutesAgo: 20, sortOrder: 1),
      wallet("C", minutesAgo: 10, sortOrder: 2),
    ]
    WalletOrdering.move(wallets, fromOffsets: [2], toOffset: 0)
    #expect(names(wallets) == ["C", "A", "B"])
  }

  @Test func `dropping a wallet where it was changes nothing`() {
    let wallets = [wallet("A", minutesAgo: 30, sortOrder: 0), wallet("B", minutesAgo: 20, sortOrder: 1)]
    WalletOrdering.move(wallets, fromOffsets: [1], toOffset: 1)
    #expect(names(wallets) == ["A", "B"])
    WalletOrdering.move(wallets, fromOffsets: [1], toOffset: 2)
    #expect(names(wallets) == ["A", "B"])
  }
}

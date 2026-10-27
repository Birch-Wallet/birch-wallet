import Foundation

/// The order wallets appear in the wallet picker, saved as each wallet's `sortOrder`.
/// Anywhere the app picks "the first wallet" uses the same order.
enum WalletOrdering {
  /// The sort for queries and fetches: by saved position, then oldest first
  static let sortDescriptors: [SortDescriptor<WalletProfile>] = [
    SortDescriptor(\.sortOrder),
    SortDescriptor(\.createdAt),
  ]

  /// `wallets` in picker order: by saved position, then oldest first, then by id so
  /// the order never depends on how they were fetched
  static func sorted(_ wallets: [WalletProfile]) -> [WalletProfile] {
    wallets.sorted {
      ($0.sortOrder, $0.createdAt, $0.id.uuidString) < ($1.sortOrder, $1.createdAt, $1.id.uuidString)
    }
  }

  /// Gives each wallet its own position, 0 through n−1, keeping the current order.
  /// Wallets saved before ordering existed all sit at 0, so the first launch with it
  /// lines them up oldest first. Returns whether any position changed.
  @discardableResult
  static func normalize(_ wallets: [WalletProfile]) -> Bool {
    var changed = false
    for (position, wallet) in sorted(wallets).enumerated() where wallet.sortOrder != position {
      wallet.sortOrder = position
      changed = true
    }
    return changed
  }

  /// Moves the wallets at `source` to `destination`, both offsets into the picker
  /// order as List's onMove reports them, and renumbers every wallet to match
  static func move(_ wallets: [WalletProfile], fromOffsets source: IndexSet, toOffset destination: Int) {
    let ordered = sorted(wallets)
    let moving = source.filter { $0 < ordered.count }.map { ordered[$0] }
    var remaining = ordered.enumerated().filter { !source.contains($0.offset) }.map(\.element)
    // The destination counts the moving rows above it, which are no longer there
    let insertAt = min(destination - source.count(in: 0 ..< destination), remaining.count)
    remaining.insert(contentsOf: moving, at: max(insertAt, 0))
    for (position, wallet) in remaining.enumerated() {
      wallet.sortOrder = position
    }
  }

  /// The position for a wallet added now: after every existing one
  static func nextSortOrder(after wallets: [WalletProfile]) -> Int {
    (wallets.map(\.sortOrder).max() ?? -1) + 1
  }
}

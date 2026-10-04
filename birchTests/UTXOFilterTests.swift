@testable import birch
import Foundation
import SwiftData
import Testing

struct UTXOFilterTests {
  // MARK: - Test Data Helpers

  private static func makeUTXO(
    _ txid: String,
    vout: UInt32 = 0,
    amount: UInt64 = 1000,
    keychain: UTXOItem.KeychainKind = .external,
    isSpent: Bool = false
  ) -> UTXOItem {
    UTXOItem(
      txid: txid, vout: vout, amount: amount, isConfirmed: true,
      keychain: keychain, derivationIndex: 0, isSpent: isSpent
    )
  }

  private static func apply(
    _ filter: UTXOFilter,
    to items: [UTXOItem],
    frozen: Set<String> = [],
    labels: [String: String] = [:],
    dates: [String: Date] = [:]
  ) -> [String] {
    filter.apply(
      to: items,
      isFrozen: { frozen.contains($0.id) },
      label: { labels[$0.id] },
      date: { dates[$0.id] }
    ).map(\.txid)
  }

  // MARK: - Persistence

  @Test func rawValueRoundTrip() {
    var filter = UTXOFilter()
    filter.showSpent = true
    filter.showChange = false
    filter.sort = .amount
    filter.ascending = true
    #expect(UTXOFilter(rawValue: filter.rawValue) == filter)
  }

  @Test func missingKeysFallBackToDefaults() {
    // A value saved before a field existed keeps what it had and defaults the rest
    let filter = UTXOFilter(rawValue: #"{"showSpent":true}"#)
    var expected = UTXOFilter()
    expected.showSpent = true
    #expect(filter == expected)
  }

  @Test func unreadableValueFallsBackToDefaults() {
    #expect(UTXOFilter(rawValue: "not json") == UTXOFilter())
    #expect(UTXOFilter(rawValue: #"{"sort":"someFutureKey"}"#) == UTXOFilter())
  }

  @Test func defaultsShowTodaysList() {
    let filter = UTXOFilter()
    #expect(filter.showSpendable && filter.showFrozen && filter.showChange)
    #expect(!filter.showSpent)
    #expect(filter.sort == .age && !filter.ascending)
    #expect(!filter.isFiltering)
  }

  @Test func isFilteringIgnoresSort() {
    var filter = UTXOFilter()
    filter.sort = .label
    filter.ascending = true
    #expect(!filter.isFiltering)
    filter.showSpent = true
    #expect(filter.isFiltering)
  }

  // MARK: - Filtering

  private static let mixed = [
    makeUTXO("spendable"),
    makeUTXO("frozen"),
    makeUTXO("spent", isSpent: true),
    makeUTXO("change", keychain: .internal),
  ]

  @Test func defaultHidesOnlySpent() {
    let result = Self.apply(UTXOFilter(), to: Self.mixed, frozen: ["frozen:0"])
    #expect(Set(result) == ["spendable", "frozen", "change"])
  }

  @Test func showSpentIncludesSpent() {
    var filter = UTXOFilter()
    filter.showSpent = true
    let result = Self.apply(filter, to: Self.mixed, frozen: ["frozen:0"])
    #expect(Set(result) == ["spendable", "frozen", "spent", "change"])
  }

  @Test func hideFrozenAndSpendable() {
    var filter = UTXOFilter()
    filter.showFrozen = false
    #expect(Set(Self.apply(filter, to: Self.mixed, frozen: ["frozen:0"])) == ["spendable", "change"])

    filter = UTXOFilter()
    filter.showSpendable = false
    #expect(Set(Self.apply(filter, to: Self.mixed, frozen: ["frozen:0"])) == ["frozen"])
  }

  @Test func spentIgnoresFrozenToggles() {
    // A leftover freeze record on a spent output must not hide it
    var filter = UTXOFilter()
    filter.showSpent = true
    filter.showSpendable = false
    filter.showFrozen = false
    #expect(Self.apply(filter, to: Self.mixed, frozen: ["spent:0"]) == ["spent"])
  }

  @Test func hideChange() {
    var filter = UTXOFilter()
    filter.showChange = false
    filter.showSpent = true
    #expect(Set(Self.apply(filter, to: Self.mixed)) == ["spendable", "frozen", "spent"])
  }

  // MARK: - Sorting

  @Test func ageSortTreatsUndatedAsNewest() {
    let items = [Self.makeUTXO("old"), Self.makeUTXO("pending"), Self.makeUTXO("new")]
    let dates = ["old:0": Date(timeIntervalSince1970: 1000), "new:0": Date(timeIntervalSince1970: 2000)]
    var filter = UTXOFilter()
    #expect(Self.apply(filter, to: items, dates: dates) == ["pending", "new", "old"])
    filter.ascending = true
    #expect(Self.apply(filter, to: items, dates: dates) == ["old", "new", "pending"])
  }

  @Test func spentSortsInlineByAge() {
    let items = [Self.makeUTXO("a"), Self.makeUTXO("b", isSpent: true), Self.makeUTXO("c")]
    let dates = [
      "a:0": Date(timeIntervalSince1970: 3000),
      "b:0": Date(timeIntervalSince1970: 2000),
      "c:0": Date(timeIntervalSince1970: 1000),
    ]
    var filter = UTXOFilter()
    filter.showSpent = true
    #expect(Self.apply(filter, to: items, dates: dates) == ["a", "b", "c"])
  }

  @Test func amountSort() {
    let items = [Self.makeUTXO("mid", amount: 500), Self.makeUTXO("big", amount: 900), Self.makeUTXO("small", amount: 100)]
    var filter = UTXOFilter()
    filter.sort = .amount
    filter.ascending = false
    #expect(Self.apply(filter, to: items) == ["big", "mid", "small"])
    filter.ascending = true
    #expect(Self.apply(filter, to: items) == ["small", "mid", "big"])
  }

  @Test func labelSortKeepsUnlabeledLast() {
    let items = [Self.makeUTXO("none"), Self.makeUTXO("b"), Self.makeUTXO("a"), Self.makeUTXO("blank")]
    let labels = ["a:0": "apple", "b:0": "Banana", "blank:0": "  "]
    var filter = UTXOFilter()
    filter.sort = .label
    filter.ascending = true
    #expect(Array(Self.apply(filter, to: items, labels: labels).prefix(2)) == ["a", "b"])
    filter.ascending = false
    #expect(Array(Self.apply(filter, to: items, labels: labels).prefix(2)) == ["b", "a"])
    #expect(Set(Self.apply(filter, to: items, labels: labels).suffix(2)) == ["none", "blank"])
  }

  @Test func sortKeyDefaultDirections() {
    #expect(!UTXOFilter.SortKey.age.defaultAscending)
    #expect(!UTXOFilter.SortKey.amount.defaultAscending)
    #expect(UTXOFilter.SortKey.label.defaultAscending)
  }

  // MARK: - Spending transaction lookup

  @Test func spendingTxidsMapsOutpointsToSpender() {
    let spender = TransactionItem(
      id: "spender", amount: -1000, fee: 200, confirmations: 3,
      timestamp: nil, isIncoming: false,
      inputs: [
        TransactionItem.TxIO(address: "tb1qa", amount: 600, prevTxid: "fund", prevVout: 1, isMine: true),
        TransactionItem.TxIO(address: "tb1qb", amount: 600, prevTxid: "fund", prevVout: 0, isMine: true),
      ],
      outputs: []
    )
    let map = UTXOListViewModel.spendingTxids(in: [spender])
    #expect(map == ["fund:1": "spender", "fund:0": "spender"])
  }

  // MARK: - Label propagation reaches spent outputs

  @Test func addressLabelPropagatesToSpentOutput() throws {
    let schema = Schema([WalletLabel.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = ModelContext(container)
    let walletID = UUID()
    context.insert(WalletLabel(walletID: walletID, type: .addr, ref: "tb1qpaid", label: "Invoice 42"))
    try context.save()

    let tx = TransactionItem(
      id: "fund", amount: 5000, fee: nil, confirmations: 10,
      timestamp: nil, isIncoming: true,
      inputs: [],
      outputs: [TransactionItem.TxIO(address: "tb1qpaid", amount: 5000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let spent = Self.makeUTXO("fund", amount: 5000, isSpent: true)
    try LabelService.propagateAddressLabels(transactions: [tx], utxos: [spent], context: context, walletID: walletID)

    let labels = try context.fetch(FetchDescriptor<WalletLabel>())
    #expect(labels.contains { $0.type == "utxo" && $0.ref == "fund:0" && $0.label == "Invoice 42" })
  }
}

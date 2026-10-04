import Foundation

/// What the UTXO list shows and in what order. Stored in AppStorage as JSON, so
/// a new field only needs a default here — older saved values decode without it.
struct UTXOFilter: Equatable {
  var showSpendable = true
  var showFrozen = true
  var showSpent = false
  var showChange = true
  var sort: SortKey = .age
  var ascending = SortKey.age.defaultAscending

  enum SortKey: String, CaseIterable, Identifiable {
    case age
    case amount
    case label

    var id: String {
      rawValue
    }

    var title: String {
      switch self {
      case .age: "Age"
      case .amount: "Amount"
      case .label: "Label"
      }
    }

    /// The direction a key starts in when picked: newest, largest, A–Z
    var defaultAscending: Bool {
      self == .label
    }

    func directionTitle(ascending: Bool) -> String {
      switch self {
      case .age: ascending ? "Oldest First" : "Newest First"
      case .amount: ascending ? "Smallest First" : "Largest First"
      case .label: ascending ? "A–Z" : "Z–A"
      }
    }
  }

  /// True when any show toggle is off its default; tints the filter button in the title row.
  var isFiltering: Bool {
    let defaults = UTXOFilter()
    return showSpendable != defaults.showSpendable
      || showFrozen != defaults.showFrozen
      || showSpent != defaults.showSpent
      || showChange != defaults.showChange
  }

  /// Filters and sorts the wallet's outputs, spent and unspent together.
  /// Spent outputs ignore the spendable/frozen toggles. Outputs with no date are
  /// unconfirmed and count as newest; unlabeled outputs sort last either way.
  func apply(
    to items: [UTXOItem],
    isFrozen: (UTXOItem) -> Bool,
    label: (UTXOItem) -> String?,
    date: (UTXOItem) -> Date?
  ) -> [UTXOItem] {
    let visible = items.filter { item in
      if !showChange, item.keychain == .internal {
        return false
      }
      if item.isSpent {
        return showSpent
      }
      return isFrozen(item) ? showFrozen : showSpendable
    }

    switch sort {
    case .age:
      let dates = Dictionary(visible.map { ($0.id, date($0) ?? .distantFuture) }, uniquingKeysWith: { first, _ in first })
      return visible.sorted { a, b in
        let da = dates[a.id]!, db = dates[b.id]!
        if da != db {
          return ascending ? da < db : da > db
        }
        return a.id < b.id
      }
    case .amount:
      return visible.sorted { a, b in
        if a.amount != b.amount {
          return ascending ? a.amount < b.amount : a.amount > b.amount
        }
        return a.id < b.id
      }
    case .label:
      let labels = Dictionary(
        visible.map { ($0.id, label($0)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") },
        uniquingKeysWith: { first, _ in first }
      )
      return visible.sorted { a, b in
        let la = labels[a.id]!, lb = labels[b.id]!
        if la.isEmpty != lb.isEmpty {
          return lb.isEmpty
        }
        let order = la.localizedStandardCompare(lb)
        if order != .orderedSame {
          return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return a.id < b.id
      }
    }
  }
}

// MARK: - Persistence

extension UTXOFilter: Codable {
  private enum CodingKeys: String, CodingKey {
    case showSpendable, showFrozen, showSpent, showChange, sort, ascending
  }

  init(from decoder: Decoder) throws {
    let defaults = UTXOFilter()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    showSpendable = try container.decodeIfPresent(Bool.self, forKey: .showSpendable) ?? defaults.showSpendable
    showFrozen = try container.decodeIfPresent(Bool.self, forKey: .showFrozen) ?? defaults.showFrozen
    showSpent = try container.decodeIfPresent(Bool.self, forKey: .showSpent) ?? defaults.showSpent
    showChange = try container.decodeIfPresent(Bool.self, forKey: .showChange) ?? defaults.showChange
    // An unknown sort key (e.g. written by a newer build) falls back to the default
    let sortRaw = try container.decodeIfPresent(String.self, forKey: .sort)
    sort = sortRaw.flatMap(SortKey.init(rawValue:)) ?? defaults.sort
    ascending = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? sort.defaultAscending
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(showSpendable, forKey: .showSpendable)
    try container.encode(showFrozen, forKey: .showFrozen)
    try container.encode(showSpent, forKey: .showSpent)
    try container.encode(showChange, forKey: .showChange)
    try container.encode(sort.rawValue, forKey: .sort)
    try container.encode(ascending, forKey: .ascending)
  }
}

/// Lets `@AppStorage` hold the filter as a JSON string. Anything unreadable
/// decodes to the defaults rather than failing.
extension UTXOFilter: RawRepresentable {
  init(rawValue: String) {
    self = (try? JSONDecoder().decode(UTXOFilter.self, from: Data(rawValue.utf8))) ?? UTXOFilter()
  }

  var rawValue: String {
    // Sorted keys keep the stored string stable for equal filters
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(self) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}

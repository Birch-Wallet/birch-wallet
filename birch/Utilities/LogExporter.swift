import Foundation

/// Query + formatting layer over `LogFileStore`. Reads persisted entries (which
/// survive app restarts) and renders them for the in-app viewer and share/copy
/// export.
enum LogExporter {
  private static let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
  }()

  /// Fetch entries from the last `hours`, optionally filtered by level set,
  /// category set, and a case-insensitive substring search over the message.
  /// Passing `nil` for a filter means "no filtering on that dimension".
  static func fetch(
    hours: Double,
    levels: Set<LogLevel>? = nil,
    categories: Set<String>? = nil,
    search: String = ""
  ) async -> [LogEntry] {
    let since = Date().addingTimeInterval(-hours * 3600)
    let entries = await LogFileStore.shared.entries(since: since)
    let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return entries.filter { entry in
      if let levels, !levels.contains(entry.l) {
        return false
      }
      if let categories, !categories.contains(entry.c) {
        return false
      }
      if !trimmedSearch.isEmpty, !entry.m.localizedCaseInsensitiveContains(trimmedSearch) {
        return false
      }
      return true
    }
  }

  /// Render one entry as `[timestamp] [LEVEL] [category] message`.
  static func format(_ entry: LogEntry) -> String {
    "[\(timestampFormatter.string(from: entry.t))] [\(entry.l.display)] [\(entry.c)] \(entry.m)"
  }

  /// Join a set of entries into a single body string, oldest first.
  static func format(_ entries: [LogEntry]) -> String {
    entries.map(format).joined(separator: "\n")
  }

  /// Full shareable text: a header (matching the prior export style) plus body.
  static func exportText(_ entries: [LogEntry], rangeDescription: String, filterDescription: String? = nil) -> String {
    guard !entries.isEmpty else {
      return "No log entries found in the last \(rangeDescription)."
    }
    var header = "Birch Logs — Exported \(timestampFormatter.string(from: Date()))\n"
      + "Entries: \(entries.count) (last \(rangeDescription))\n"
    if let filterDescription, !filterDescription.isEmpty {
      header += "Filters: \(filterDescription)\n"
    }
    header += String(repeating: "─", count: 60) + "\n"
    return header + format(entries)
  }
}

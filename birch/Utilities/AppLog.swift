import Foundation
import OSLog

// MARK: - Log Level

/// Severity of a log entry, ordered ascending for filtering.
enum LogLevel: String, Codable, CaseIterable, Comparable {
  case debug
  case info
  case warning
  case error
  case critical

  private var order: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .warning: 2
    case .error: 3
    case .critical: 4
    }
  }

  static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.order < rhs.order
  }

  /// Upper-cased label used in the human-readable export.
  var display: String {
    rawValue.uppercased()
  }
}

// MARK: - Log Category

/// Subsystem a log entry belongs to. Drives the viewer's category filter and
/// the os.Logger category so Console.app grouping stays meaningful.
enum LogCategory: String, Codable, CaseIterable {
  case app // lifecycle, navigation, settings
  case security // app lock / biometrics
  case wallet // wallet load / create / switch / delete
  case sync // BDK sync + Electrum lifecycle
  case send // send + bump-fee + broadcast
  case psbt // PSBT flow coordination + saved PSBTs
  case qr // UR / BBQR encode / decode / scanner / video
  case wizard // setup wizard
  case receive // receive + address derivation
  case utxo // UTXO list + freeze / unfreeze
  case transactions // transaction list + detail
  case labels // address / UTXO / BIP329 labels
  case fiat // fiat price fetching
  case export // descriptor PDF / other exports
}

// MARK: - Log Entry

/// A single persisted log line. Field names are short to keep the on-disk
/// JSON Lines representation compact; `c` is stored as a raw String so entries
/// written by an older build with a since-renamed category still decode.
struct LogEntry: Codable {
  let t: Date
  let l: LogLevel
  let c: String
  let m: String
}

// MARK: - AppLog

/// Value-type façade mirroring `os.Logger`. Each message is written both to the
/// unified logging system (so Console.app keeps working) and to the rotating
/// on-disk store that backs the in-app Debug Logs viewer and survives restarts.
struct AppLog {
  let category: LogCategory

  init(_ category: LogCategory) {
    self.category = category
  }

  func debug(_ message: @autoclosure () -> String) {
    log(.debug, message())
  }

  func info(_ message: @autoclosure () -> String) {
    log(.info, message())
  }

  func warning(_ message: @autoclosure () -> String) {
    log(.warning, message())
  }

  func error(_ message: @autoclosure () -> String) {
    log(.error, message())
  }

  func critical(_ message: @autoclosure () -> String) {
    log(.critical, message())
  }

  private func log(_ level: LogLevel, _ message: String) {
    let osLogger = AppLog.osLogger(for: category)
    switch level {
    case .debug: osLogger.debug("\(message, privacy: .public)")
    case .info: osLogger.info("\(message, privacy: .public)")
    case .warning: osLogger.warning("\(message, privacy: .public)")
    case .error: osLogger.error("\(message, privacy: .public)")
    case .critical: osLogger.critical("\(message, privacy: .public)")
    }
    LogFileStore.shared.append(LogEntry(t: Date(), l: level, c: category.rawValue, m: message))
  }

  /// One os.Logger per category, built once. The dictionary is immutable after
  /// initialization, so concurrent reads on any thread are safe without locking.
  private static let osLoggers: [LogCategory: Logger] = {
    let subsystem = Bundle.main.bundleIdentifier ?? "birch"
    return Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
      ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })
  }()

  private static func osLogger(for category: LogCategory) -> Logger {
    osLoggers[category] ?? Logger(subsystem: Bundle.main.bundleIdentifier ?? "birch", category: category.rawValue)
  }
}

// MARK: - Log File Store

/// Rotating, append-only JSON Lines log file living alongside the BDK database
/// in the app's Application Support container (same iOS sandbox and
/// data-protection-at-rest as wallet data).
///
/// Thread-safety: all file I/O runs on a private serial queue, so `append` is a
/// cheap non-blocking enqueue callable from any actor (including the
/// `@MainActor` services) and reads see a consistent file.
final class LogFileStore: @unchecked Sendable {
  static let shared = LogFileStore(directory: Constants.logsDirectory())

  private let directory: URL
  private let fileURL: URL
  private let archiveURL: URL
  private let queue = DispatchQueue(label: "net.klockenga.birch.logstore", qos: .utility)

  private var handle: FileHandle?
  private var currentSize: UInt64 = 0

  /// Rotate the active file once it passes this size.
  private let maxFileSize: UInt64
  /// Discard the rotated archive once it is older than this on launch.
  private let archiveMaxAge: TimeInterval

  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }()

  private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }()

  init(
    directory: URL,
    maxFileSize: UInt64 = 5 * 1024 * 1024, // 5 MB
    archiveMaxAge: TimeInterval = 7 * 24 * 3600 // 7 days
  ) {
    self.directory = directory
    self.maxFileSize = maxFileSize
    self.archiveMaxAge = archiveMaxAge
    fileURL = directory.appendingPathComponent("birch.log")
    archiveURL = directory.appendingPathComponent("birch.log.1")
  }

  // MARK: Writing

  func append(_ entry: LogEntry) {
    queue.async { [weak self] in
      self?.writeLocked(entry)
    }
  }

  private func writeLocked(_ entry: LogEntry) {
    guard var data = try? encoder.encode(entry) else { return }
    data.append(0x0A) // newline delimiter
    if handle == nil {
      openHandle()
    }
    guard let handle else { return }
    do {
      try handle.write(contentsOf: data)
      currentSize += UInt64(data.count)
      if currentSize >= maxFileSize {
        rotate()
      }
    } catch {
      // Best-effort logging: drop the line rather than crash the app.
    }
  }

  private func openHandle() {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: fileURL.path) {
      fm.createFile(atPath: fileURL.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: fileURL)
    currentSize = (try? handle?.seekToEnd()) ?? 0
  }

  private func rotate() {
    let fm = FileManager.default
    try? handle?.close()
    handle = nil
    try? fm.removeItem(at: archiveURL)
    try? fm.moveItem(at: fileURL, to: archiveURL)
    currentSize = 0
    openHandle()
  }

  // MARK: Maintenance

  /// Prune a stale archive and open the write handle. Call once at launch.
  func performStartupMaintenance() {
    queue.async { [weak self] in
      guard let self else { return }
      let fm = FileManager.default
      if let attrs = try? fm.attributesOfItem(atPath: archiveURL.path),
         let modDate = attrs[.modificationDate] as? Date,
         Date().timeIntervalSince(modDate) > archiveMaxAge
      {
        try? fm.removeItem(at: archiveURL)
      }
      openHandle()
    }
  }

  // MARK: Reading

  /// All entries at or after `since`, oldest first (archive then active file).
  func entries(since: Date) async -> [LogEntry] {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        guard let self else { continuation.resume(returning: []); return }
        var result: [LogEntry] = []
        for url in [archiveURL, fileURL] {
          guard let data = try? Data(contentsOf: url) else { continue }
          for lineSlice in data.split(separator: 0x0A) {
            if let entry = try? decoder.decode(LogEntry.self, from: Data(lineSlice)), entry.t >= since {
              result.append(entry)
            }
          }
        }
        continuation.resume(returning: result)
      }
    }
  }

  /// Await completion of all currently-enqueued writes. For tests and pre-export.
  func flush() async {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }
}

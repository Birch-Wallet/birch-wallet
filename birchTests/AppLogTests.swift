@testable import birch
import Foundation
import Testing

@Suite("AppLog / LogFileStore")
struct AppLogTests {
  /// Fresh unique temp directory per store so tests never share state.
  private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("birch-logtests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func entry(_ level: LogLevel, _ category: String, _ message: String) -> LogEntry {
    LogEntry(t: Date(), l: level, c: category, m: message)
  }

  @Test("append/flush/read round-trips and preserves fields")
  func roundTrip() async {
    let store = LogFileStore(directory: makeTempDir())
    store.append(entry(.info, "sync", "hello world"))
    store.append(entry(.error, "send", "broadcast failed"))
    await store.flush()

    let entries = await store.entries(since: .distantPast)
    #expect(entries.count == 2)
    #expect(entries[0].l == .info)
    #expect(entries[0].c == "sync")
    #expect(entries[0].m == "hello world")
    #expect(entries[1].l == .error)
    #expect(entries[1].c == "send")
    #expect(entries[1].m == "broadcast failed")
  }

  @Test("entries(since:) filters out older entries")
  func filtersByDate() async {
    let store = LogFileStore(directory: makeTempDir())
    store.append(LogEntry(t: Date().addingTimeInterval(-3600), l: .info, c: "app", m: "old"))
    store.append(LogEntry(t: Date(), l: .info, c: "app", m: "new"))
    await store.flush()

    let recent = await store.entries(since: Date().addingTimeInterval(-60))
    #expect(recent.count == 1)
    #expect(recent.first?.m == "new")
  }

  @Test("rotation preserves pre-rotation entries in the archive")
  func rotationKeepsArchiveReadable() async {
    // Small cap so a single large message forces exactly one rotation.
    let store = LogFileStore(directory: makeTempDir(), maxFileSize: 1000)

    // Three short "old" entries stay under the cap.
    for i in 0 ..< 3 {
      store.append(entry(.info, "sync", "old-\(i)"))
    }
    // One large entry pushes the active file past the cap, triggering a rotation.
    store.append(entry(.info, "sync", String(repeating: "x", count: 900)))
    // Two short "new" entries land in the fresh active file (still under the cap).
    for i in 0 ..< 2 {
      store.append(entry(.info, "sync", "new-\(i)"))
    }
    await store.flush()

    let entries = await store.entries(since: .distantPast)
    let messages = entries.map(\.m)
    #expect(entries.count == 6)
    #expect(messages.contains("old-0"))
    #expect(messages.contains("old-2"))
    #expect(messages.contains("new-1"))
  }

  @Test("startup maintenance deletes a stale archive but keeps a recent one")
  func startupMaintenancePrunesOldArchive() async {
    let fm = FileManager.default

    // Stale archive (8 days old) should be removed.
    let staleDir = makeTempDir()
    let staleArchive = staleDir.appendingPathComponent("birch.log.1")
    try? "{}".data(using: .utf8)?.write(to: staleArchive)
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: staleArchive.path)
    let staleStore = LogFileStore(directory: staleDir)
    staleStore.performStartupMaintenance()
    await staleStore.flush()
    #expect(!fm.fileExists(atPath: staleArchive.path))

    // Recent archive (1 hour old) should survive.
    let freshDir = makeTempDir()
    let freshArchive = freshDir.appendingPathComponent("birch.log.1")
    try? "{}".data(using: .utf8)?.write(to: freshArchive)
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: freshArchive.path)
    let freshStore = LogFileStore(directory: freshDir)
    freshStore.performStartupMaintenance()
    await freshStore.flush()
    #expect(fm.fileExists(atPath: freshArchive.path))
  }

  @Test("concurrent appends produce no dropped or corrupted lines")
  func concurrentAppends() async {
    let store = LogFileStore(directory: makeTempDir())
    let count = 500

    await withTaskGroup(of: Void.self) { group in
      for i in 0 ..< count {
        group.addTask {
          store.append(entry(.debug, "sync", "concurrent-\(i)"))
        }
      }
    }
    await store.flush()

    let entries = await store.entries(since: .distantPast)
    // Every line must decode cleanly and none may be lost.
    #expect(entries.count == count)
    #expect(Set(entries.map(\.m)).count == count)
  }
}

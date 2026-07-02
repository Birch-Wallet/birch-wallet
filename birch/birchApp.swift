import SwiftData
import SwiftUI

@main
struct birchApp: App {
  let modelContainer: ModelContainer

  init() {
    #if DEBUG
      if CommandLine.arguments.contains("-UITesting") {
        // Clear UserDefaults so the app starts fresh (shows setup wizard)
        if let bundleID = Bundle.main.bundleIdentifier {
          UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // Clear Keychain (PIN, lockout state)
        KeychainHelper.deleteAll()
      }
    #endif

    do {
      let schema = Schema([WalletProfile.self, CosignerInfo.self, WalletLabel.self, FrozenUTXO.self, SavedPSBT.self])
      #if DEBUG
        let isUITesting = CommandLine.arguments.contains("-UITesting")
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)
      #else
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
      #endif
      modelContainer = try ModelContainer(for: schema, configurations: [config])
      BitcoinService.shared.modelContainer = modelContainer
    } catch {
      fatalError("Failed to create ModelContainer: \(error)")
    }

    LogFileStore.shared.performStartupMaintenance()
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    AppLog(.app).info("App launch — Birch \(version) (\(build)), \(os)")
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
    .modelContainer(modelContainer)
  }
}

// MARK: - Root View

struct RootView: View {
  let themeManager = ThemeManager.shared
  @AppStorage(Constants.themeKey) private var themeRaw = AppTheme.system.rawValue
  @Environment(\.colorScheme) private var systemColorScheme

  private var isSystemTheme: Bool {
    AppTheme(rawValue: themeRaw) == .system
  }

  var body: some View {
    ContentView()
      // When System theme is active, pass nil so SwiftUI follows the OS —
      // this lets @Environment(\.colorScheme) reflect real OS changes.
      .preferredColorScheme(isSystemTheme ? nil : themeManager.theme.colorScheme)
      .task(id: systemColorScheme) {
        // Using task(id:) instead of onChange so that transient colorScheme
        // flips during sheet dismissal animations are cancelled before they
        // apply, preventing the theme from briefly snapping to the wrong palette.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        if isSystemTheme {
          themeManager.applySystemColorScheme(systemColorScheme)
        }
      }
      .onChange(of: themeRaw) { _, new in
        if AppTheme(rawValue: new) == .system {
          themeManager.applySystemColorScheme(systemColorScheme)
        }
      }
  }
}

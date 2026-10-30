import LocalAuthentication
import SwiftData
import SwiftUI

private let logger = AppLog(.app)

/// How long the choice list takes to pop back to Settings. Work a choice sets
/// off (a price fetch, a new palette) waits this long, so redrawing the screen
/// doesn't land mid-animation.
private let popDelay: Duration = .milliseconds(400)

struct SettingsView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var showLogExport = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text("Settings")
          .font(.hbAmountLarge)
          .foregroundStyle(Color.hbTextPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 4)

        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            // Security
            AppLockSettingsSection()

            // Fee Estimation
            SettingsSection("Fee Estimation") {
              FeeSettingsRow()
            }

            // Currency Display
            SettingsSection("Currency Display") {
              DenominationSettingsRow()
              HBDivider()
              FiatSettingsRow()
            }

            // Appearance
            SettingsSection("Appearance") {
              AppearanceSettingsRow()
            }

            // App Icon
            SettingsSection("App Icon") {
              AppIconSettingsRow()
            }

            // About
            SettingsSection("About") {
              HStack {
                Text("Version")
                  .foregroundStyle(Color.hbTextPrimary)
                Spacer()
                Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                  .foregroundStyle(Color.hbTextSecondary)

                Button(action: { showLogExport = true }) {
                  Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.hbTextSecondary)
                }
                .buttonStyle(.plain)
              }
              .settingsRow()
            }
          }
          .padding(16)
        }
      }
      .background(Color.hbBackground)
      .navigationTitle("")
      .sheet(isPresented: $showLogExport) {
        LogExportSheet()
          .birchSheet()
      }
    }
  }
}

// MARK: - Section and Rows

/// A titled card of settings rows, the same lifted card as the other screens
struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color(.secondaryLabel))
        .padding(.horizontal, 4)

      // Rows carry most of their own height, like a list; the card adds a
      // little above and below so a single row doesn't sit tight to its edges
      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
      .birchCard()
    }
  }
}

extension View {
  /// A settings row's height: 8pt above and below, at least 52pt in all
  func settingsRow() -> some View {
    padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
  }
}

/// Label on the left, the chosen value on the right. Tapping the row pushes a
/// list of the options, as in iOS Settings. A menu would collapse back into the
/// value with iOS 26's morph, which leaves it misaligned for a moment.
private struct SettingsPickerRow<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [Value]
  let optionTitle: (Value) -> String

  init(_ title: String, selection: Binding<Value>, options: [Value], optionTitle: @escaping (Value) -> String) {
    self.title = title
    _selection = selection
    self.options = options
    self.optionTitle = optionTitle
  }

  var body: some View {
    NavigationLink {
      SettingsChoiceList(title: title, selection: $selection, options: options, optionTitle: optionTitle)
    } label: {
      HStack {
        Text(title)
          .foregroundStyle(Color.hbTextPrimary)
        Spacer()
        Text(optionTitle(selection))
          .foregroundStyle(Color.hbTextSecondary)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .settingsRow()
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityValue(optionTitle(selection))
  }
}

/// The options for one setting, the chosen one checked. Choosing pops back.
private struct SettingsChoiceList<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [Value]
  let optionTitle: (Value) -> String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(Array(options.enumerated()), id: \.element) { index, option in
          if index > 0 {
            HBDivider()
          }
          Button {
            selection = option
            dismiss()
          } label: {
            HStack {
              Text(optionTitle(option))
                .foregroundStyle(Color.hbTextPrimary)
              Spacer()
              if option == selection {
                Image(systemName: "checkmark")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(Color.hbSelection)
              }
            }
            .settingsRow()
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(option == selection ? .isSelected : [])
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
      .birchCard()
      .padding(16)
    }
    .background(Color.hbBackground)
    .navigationTitle(title)
  }
}

// MARK: - Appearance Settings

private struct AppearanceSettingsRow: View {
  @AppStorage(Constants.themeKey) private var themeRaw = AppTheme.system.rawValue

  var body: some View {
    SettingsPickerRow(
      "Theme",
      selection: $themeRaw,
      options: AppTheme.allCases.map(\.rawValue),
      optionTitle: { AppTheme(rawValue: $0)?.displayName ?? $0 },
    )
    .onChange(of: themeRaw) { _, new in
      guard let t = AppTheme(rawValue: new) else { return }
      logger.info("Theme changed to \(t.displayName)")
      Task {
        try? await Task.sleep(for: popDelay)
        ThemeManager.shared.apply(t)
      }
    }
  }
}

// MARK: - App Icon Settings

private enum AppIconOption: String, CaseIterable, Identifiable {
  case light
  case dark

  var id: String {
    rawValue
  }

  /// Name passed to `UIApplication.setAlternateIconName`; `nil` selects the primary icon.
  var alternateIconName: String? {
    switch self {
    case .light: nil
    case .dark: "AppIcon-Dark"
    }
  }

  var displayName: String {
    switch self {
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var previewAssetName: String {
    switch self {
    case .light: "AppIconPreviewLight"
    case .dark: "AppIconPreviewDark"
    }
  }

  static var current: AppIconOption {
    UIApplication.shared.alternateIconName == "AppIcon-Dark" ? .dark : .light
  }
}

private struct AppIconSettingsRow: View {
  @State private var selected: AppIconOption = .current

  var body: some View {
    HStack(spacing: 12) {
      ForEach(AppIconOption.allCases) { option in
        AppIconTile(option: option, isSelected: selected == option) {
          select(option)
        }
      }
    }
    .padding(.vertical, 8)
  }

  private func select(_ option: AppIconOption) {
    guard selected != option else { return }
    UIApplication.shared.setAlternateIconName(option.alternateIconName) { error in
      Task { @MainActor in
        if let error {
          logger.error("Failed to set app icon: \(error.localizedDescription)")
        } else {
          logger.info("App icon changed to \(option.displayName)")
          selected = option
        }
      }
    }
  }
}

private struct AppIconTile: View {
  let option: AppIconOption
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 8) {
        Image(option.previewAssetName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay {
            if isSelected {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.hbSelection, lineWidth: 1.5)
            }
          }

        HStack(spacing: 4) {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 12))
              .foregroundStyle(Color.hbSelection)
          }
          Text(option.displayName)
            .font(.hbBody(13))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Denomination Settings

private struct DenominationSettingsRow: View {
  @AppStorage(Constants.denominationKey) private var denomination: String = Denomination.sats.rawValue

  var body: some View {
    SettingsPickerRow(
      "Bitcoin Unit",
      selection: $denomination,
      options: Denomination.allCases.map(\.rawValue),
      optionTitle: { Denomination(rawValue: $0)?.label ?? $0 },
    )
    .accessibilityIdentifier("bitcoinUnitPicker")
    .onChange(of: denomination) { _, new in
      logger.info("Bitcoin unit changed to \(new)")
    }
  }
}

// MARK: - Fee Settings

private struct FeeSettingsRow: View {
  @AppStorage(Constants.feeSourceKey) private var feeSourceRaw = FeeSource.electrum.rawValue

  var body: some View {
    SettingsPickerRow(
      "Fee Source",
      selection: $feeSourceRaw,
      options: FeeSource.allCases.map(\.rawValue),
      optionTitle: { FeeSource(rawValue: $0)?.displayName ?? $0 },
    )
    .onChange(of: feeSourceRaw) { _, new in
      logger.info("Fee source changed to \(new)")
    }
  }
}

// MARK: - Fiat Settings

private struct FiatSettingsRow: View {
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @AppStorage(Constants.fiatCurrencyKey) private var fiatCurrency = "USD"
  @AppStorage(Constants.fiatSourceKey) private var fiatSourceRaw = FiatSource.zeus.rawValue
  @State private var fiatService = FiatPriceService.shared

  var body: some View {
    VStack(spacing: 0) {
      Toggle(isOn: Binding(
        get: { fiatEnabled },
        set: { new in
          logger.info("Fiat display \(new ? "enabled" : "disabled")")
          fiatEnabled = new
        },
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Show Fiat Price")
            .foregroundStyle(Color.hbTextPrimary)
          Text("Display estimated fiat value alongside bitcoin amounts")
            .font(.hbBody(12))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .tint(Color.hbToggle)
      .settingsRow()
      .accessibilityIdentifier("showFiatPriceToggle")

      if fiatEnabled {
        HBDivider()
        SettingsPickerRow(
          "Price Source",
          selection: $fiatSourceRaw,
          options: FiatSource.allCases.map(\.rawValue),
          optionTitle: { FiatSource(rawValue: $0)?.displayName ?? $0 },
        )
        .onChange(of: fiatSourceRaw) {
          logger.info("Fiat source changed to \(fiatSourceRaw)")
          Task {
            try? await Task.sleep(for: popDelay)
            fiatService.resetCache()
            await fiatService.fetchRates()
          }
        }

        HBDivider()
        SettingsPickerRow(
          "Currency",
          selection: $fiatCurrency,
          options: FiatPriceService.availableCurrencies.map(\.code),
          optionTitle: { $0 },
        )
      }
    }
  }
}

// MARK: - App Lock Settings

private struct AppLockSettingsSection: View {
  @AppStorage(Constants.appLockEnabledKey) private var appLockEnabled = false
  @AppStorage(Constants.appLockTimeoutKey) private var lockTimeout = 60
  @State private var showBiometricError = false
  @State private var biometricErrorMessage = ""
  @State private var showSetPIN = false
  @State private var showRemovePIN = false
  @State private var lockVM = AppLockViewModel()

  private static let timeoutOptions: [(String, Int)] = [
    ("1 minute", 60),
    ("5 minutes", 300),
    ("15 minutes", 900),
    ("30 minutes", 1800),
    ("60 minutes", 3600),
  ]

  private var biometricLabel: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    switch context.biometryType {
    case .faceID: return "Face ID"
    case .touchID: return "Touch ID"
    case .opticID: return "Optic ID"
    default: return "Passcode"
    }
  }

  var body: some View {
    SettingsSection("Security") {
      Toggle(isOn: Binding(
        get: { appLockEnabled },
        set: { newValue in
          if newValue {
            authenticateToEnable()
          } else {
            logger.info("App lock disabled")
            lockVM.removePIN()
            appLockEnabled = false
          }
        },
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("App Lock")
            .foregroundStyle(Color.hbTextPrimary)
          Text("Require \(biometricLabel) to open app")
            .font(.hbBody(12))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .tint(Color.hbToggle)
      .settingsRow()
      .alert("Authentication Unavailable", isPresented: $showBiometricError) {
        Button("OK") {}
      } message: {
        Text(biometricErrorMessage)
      }
      .sheet(isPresented: $showSetPIN) {
        SetPINSheet(lockVM: lockVM)
          .birchSheet()
      }
      .sheet(isPresented: $showRemovePIN) {
        RemovePINSheet(lockVM: lockVM)
          .birchSheet()
      }

      if appLockEnabled {
        HBDivider()
        SettingsPickerRow(
          "Lock After",
          selection: $lockTimeout,
          options: Self.timeoutOptions.map(\.1),
          optionTitle: { seconds in Self.timeoutOptions.first { $0.1 == seconds }?.0 ?? "\(seconds / 60) minutes" },
        )
        .onChange(of: lockTimeout) { _, new in
          logger.info("Lock timeout changed to \(new)s")
        }

        HBDivider()
        if lockVM.hasPIN {
          Button(role: .destructive) {
            showRemovePIN = true
          } label: {
            Text("Remove PIN")
              .foregroundStyle(Color.hbError)
              .settingsRow()
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        } else {
          Button {
            showSetPIN = true
          } label: {
            HStack {
              Text("Add Additional PIN")
                .foregroundStyle(Color.hbLink)
              Spacer()
              Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.hbTextSecondary)
            }
            .settingsRow()
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func authenticateToEnable() {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      biometricErrorMessage = error?.localizedDescription ?? "Authentication is not available on this device."
      showBiometricError = true
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Verify your identity to enable app lock") { success, _ in
      DispatchQueue.main.async {
        if success {
          logger.info("App lock enabled")
          appLockEnabled = true
        }
      }
    }
  }
}

// MARK: - Set PIN Sheet

private struct SetPINSheet: View {
  @Bindable var lockVM: AppLockViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var step: SetPINStep = .create
  @State private var firstPIN = ""
  @State private var confirmPIN = ""
  @State private var error = ""

  private enum SetPINStep {
    case create
    case confirm
  }

  var body: some View {
    NavigationStack {
      VStack {
        Spacer()

        switch step {
        case .create:
          PINPadView(
            title: "Create PIN",
            subtitle: error,
            dotCount: 8,
            minDigits: 4,
            mode: .create,
            pin: $firstPIN,
            isDisabled: false,
            onComplete: { pin in
              firstPIN = pin
              error = ""
              confirmPIN = ""
              step = .confirm
            },
            hint: "Choose a PIN between 4 and 8 digits",
          )
        case .confirm:
          PINPadView(
            title: "Confirm PIN",
            subtitle: error,
            dotCount: firstPIN.count,
            minDigits: firstPIN.count,
            mode: .verify,
            pin: $confirmPIN,
            isDisabled: false,
            onComplete: { pin in
              if pin == firstPIN {
                lockVM.setPIN(pin)
                dismiss()
              } else {
                error = "PINs don't match — try again"
                firstPIN = ""
                confirmPIN = ""
                step = .create
              }
            },
          )
        }

        Spacer()
      }
      .padding(.horizontal, 16)
      .background(Color.hbBackground)
      .navigationTitle("Set PIN")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: false))
        }
        .hbHidesGlassBackground()
      }
    }
  }
}

// MARK: - Remove PIN Sheet

private struct RemovePINSheet: View {
  @Bindable var lockVM: AppLockViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var pin = ""
  @State private var error = ""
  @State private var lockoutTimer: Timer?

  var body: some View {
    NavigationStack {
      VStack {
        Spacer()

        PINPadView(
          title: "Enter Current PIN",
          subtitle: lockVM.isLockedOut ? lockVM.lockoutRemainingText : error,
          dotCount: lockVM.storedPINLength,
          minDigits: lockVM.storedPINLength,
          mode: .verify,
          pin: $pin,
          isDisabled: lockVM.isLockedOut,
          onComplete: { entered in
            if lockVM.verifyPIN(entered) {
              // verifyPIN unlocked — re-lock since we're in settings
              lockVM.isLocked = false
              lockVM.removePIN()
              dismiss()
            } else {
              error = lockVM.pinError
              pin = ""
              startLockoutTimerIfNeeded()
            }
          },
        )

        Spacer()
      }
      .padding(.horizontal, 16)
      .background(Color.hbBackground)
      .navigationTitle("Remove PIN")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: false))
        }
        .hbHidesGlassBackground()
      }
      .onAppear { startLockoutTimerIfNeeded() }
      .onDisappear { lockoutTimer?.invalidate() }
    }
  }

  private func startLockoutTimerIfNeeded() {
    guard lockVM.isLockedOut else { return }
    lockoutTimer?.invalidate()
    lockoutTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak lockVM] timer in
      MainActor.assumeIsolated {
        guard let lockVM else {
          timer.invalidate()
          return
        }
        if !lockVM.isLockedOut {
          timer.invalidate()
          error = ""
        } else {
          error = lockVM.lockoutRemainingText
        }
      }
    }
  }
}

// MARK: - Log Export Sheet

private struct LogExportSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// All entries loaded for the current time range, before in-memory filtering.
  @State private var allEntries: [LogEntry] = []
  @State private var isLoading = true
  @State private var copied = false
  @State private var hours: Double = 1
  @State private var selectedLevel: LogLevel?
  @State private var selectedCategory: String?
  @State private var searchText = ""
  /// Non-nil while the pre-export privacy warning is shown; carries the pending action.
  @State private var pendingExport: ExportAction?

  private enum ExportAction { case copy, share }

  /// Cap on rendered rows to keep the view responsive; export still includes all.
  private let displayCap = 5000

  private static let timeRanges: [(label: String, hours: Double)] = [
    ("1h", 1), ("12h", 12), ("24h", 24), ("3d", 72), ("7d", 168),
  ]

  private var rangeLabel: String {
    Self.timeRanges.first { $0.hours == hours }?.label ?? "\(Int(hours))h"
  }

  private var availableCategories: [String] {
    Set(allEntries.map(\.c)).sorted()
  }

  private var filteredEntries: [LogEntry] {
    let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return allEntries.filter { entry in
      if let selectedLevel, entry.l != selectedLevel {
        return false
      }
      if let selectedCategory, entry.c != selectedCategory {
        return false
      }
      if !search.isEmpty, !entry.m.localizedCaseInsensitiveContains(search) {
        return false
      }
      return true
    }
  }

  private var filterDescription: String {
    var parts: [String] = []
    if let selectedLevel {
      parts.append("level \(selectedLevel.display)")
    }
    if let selectedCategory {
      parts.append("category \(selectedCategory)")
    }
    let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !search.isEmpty {
      parts.append("search \"\(search)\"")
    }
    return parts.joined(separator: ", ")
  }

  private var exportText: String {
    LogExporter.exportText(filteredEntries, rangeDescription: rangeLabel, filterDescription: filterDescription)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        controls

        if isLoading {
          Spacer()
          ProgressView().tint(Color.hbProgress)
          Spacer()
        } else {
          logList
        }
      }
      .background(Color.hbBackground)
      .navigationTitle("Debug Logs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: true))
        }
        .hbHidesGlassBackground()
        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 12) {
            Button { pendingExport = .share } label: {
              Image(systemName: "square.and.arrow.up").font(.system(size: 14))
            }
            .foregroundStyle(Color.hbBrandInk)

            Button { pendingExport = .copy } label: {
              Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14))
                .foregroundStyle(copied ? Color.hbSuccess : Color.hbBrandInk)
            }
          }
        }
      }
      .onAppear { loadLogs() }
      .alert("Logs contain private wallet data", isPresented: exportWarningBinding, presenting: pendingExport) { action in
        Button(action == .copy ? "Copy Anyway" : "Share Anyway") { performExport(action) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("These logs include your wallet's transaction IDs, addresses, amounts, and descriptors. Only copy or share them with people and apps you trust.")
      }
    }
  }

  /// Drives the export warning alert; clearing it cancels the pending action.
  private var exportWarningBinding: Binding<Bool> {
    Binding(get: { pendingExport != nil }, set: {
      if !$0 {
        pendingExport = nil
      }
    })
  }

  // MARK: Controls

  private var controls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        Text("Last")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        Picker("", selection: $hours) {
          ForEach(Self.timeRanges, id: \.hours) { range in
            Text(range.label).tag(range.hours)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: hours) { loadLogs() }
      }

      HStack(spacing: 12) {
        Menu {
          Button("All levels") { selectedLevel = nil }
          ForEach(LogLevel.allCases, id: \.self) { level in
            Button(level.display) { selectedLevel = level }
          }
        } label: {
          filterLabel(icon: "line.3.horizontal.decrease.circle", text: selectedLevel?.display ?? "All levels")
        }

        Menu {
          Button("All categories") { selectedCategory = nil }
          ForEach(availableCategories, id: \.self) { category in
            Button(category) { selectedCategory = category }
          }
        } label: {
          filterLabel(icon: "square.grid.2x2", text: selectedCategory ?? "All categories")
        }

        Spacer()
      }

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 13))
          .foregroundStyle(Color.hbTextSecondary)
        TextField("Search messages", text: $searchText)
          .font(.hbMono(12))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 13))
              .foregroundStyle(Color.hbTextSecondary)
          }
        }
      }
      .padding(8)
      .background(Color.hbSurface, in: .rect(cornerRadius: 8, style: .continuous))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func filterLabel(icon: String, text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon).font(.system(size: 12))
      Text(text).font(.hbLabel())
      Image(systemName: "chevron.down").font(.system(size: 9))
    }
    .foregroundStyle(Color.hbBrandInk)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.hbSurface, in: Capsule())
  }

  // MARK: Log list

  @ViewBuilder private var logList: some View {
    let entries = filteredEntries
    let shown = Array(entries.suffix(displayCap))
    VStack(spacing: 0) {
      HStack {
        Text(entries.count == 1 ? "1 entry" : "\(entries.count) entries")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        if entries.count > displayCap {
          Text("(showing latest \(displayCap))")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
        }
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 6)

      if shown.isEmpty {
        Spacer()
        Text("No log entries match.")
          .font(.hbBody())
          .foregroundStyle(Color.hbTextSecondary)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
              Text(LogExporter.format(entry))
                .font(.hbMono(11))
                .foregroundStyle(tint(for: entry.l))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
          }
          .padding(12)
        }
        .background(Color.hbSurface)
      }
    }
  }

  private func tint(for level: LogLevel) -> Color {
    switch level {
    case .debug: Color.hbTextSecondary
    case .info: Color.hbTextPrimary
    case .warning: Color.hbWarning
    case .error, .critical: Color.hbError
    }
  }

  // MARK: Actions

  private func loadLogs() {
    isLoading = true
    Task {
      let entries = await LogExporter.fetch(hours: hours)
      await MainActor.run {
        allEntries = entries
        isLoading = false
      }
    }
  }

  private func performExport(_ action: ExportAction) {
    switch action {
    case .copy:
      copyLogs()
    case .share:
      // Defer so the warning alert finishes dismissing before we present the share sheet.
      DispatchQueue.main.async { shareLogs() }
    }
  }

  private func copyLogs() {
    UIPasteboard.general.string = exportText
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      await MainActor.run { copied = false }
    }
  }

  private func shareLogs() {
    // Write to a temp .txt file so the share sheet shows a proper filename.
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("birch-logs.txt")
    try? exportText.data(using: .utf8)?.write(to: tempURL)

    let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          var topVC = windowScene.windows.first?.rootViewController else { return }
    while let presented = topVC.presentedViewController {
      topVC = presented
    }
    if let popover = activityVC.popoverPresentationController {
      popover.sourceView = topVC.view
      popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    topVC.present(activityVC, animated: true)
  }
}

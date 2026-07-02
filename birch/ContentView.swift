import LocalAuthentication
import SwiftData
import SwiftUI

private let logger = AppLog(.app)

struct ContentView: View {
  @Query private var wallets: [WalletProfile]
  @AppStorage(Constants.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false
  @AppStorage(Constants.appLockEnabledKey) private var appLockEnabled = false
  @AppStorage(Constants.appLockTimeoutKey) private var lockTimeout = 60
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.modelContext) private var modelContext
  @State private var lockVM = AppLockViewModel()
  @State private var showPrivacyScreen = false

  private var hasActiveWallet: Bool {
    wallets.contains { $0.isActive }
  }

  private var shouldShowLock: Bool {
    appLockEnabled && lockVM.isLocked
  }

  var body: some View {
    ZStack {
      Group {
        if shouldShowLock {
          // Don't render main UI while locked — prevents wallet load/sync
          Color.hbBackground.ignoresSafeArea()
        } else if hasCompletedOnboarding, hasActiveWallet {
          MainTabView()
        } else {
          SetupWizardView()
        }
      }
      .background(Color.hbBackground)

      if shouldShowLock {
        AppLockView(lockVM: lockVM, modelContext: modelContext)
      }

      // Privacy screen — hides content in app switcher when app lock is enabled
      if showPrivacyScreen, !shouldShowLock {
        PrivacyOverlayView()
      }
    }
    .onAppear {
      // If wallets exist but none are active (e.g. after a failed delete),
      // activate the first one so the app doesn't fall through to the setup wizard.
      if !wallets.isEmpty, !hasActiveWallet {
        logger.info("No active wallet found — activating first available wallet")
        let first = wallets[0]
        first.isActive = true
        UserDefaults.standard.set(first.id.uuidString, forKey: Constants.activeWalletIDKey)
        try? modelContext.save()
      }
      if appLockEnabled {
        logger.info("App launched with lock enabled")
        lockVM.authenticate()
      } else {
        logger.info("App launched (lock disabled)")
        lockVM.isLocked = false
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      switch newPhase {
      case .background:
        logger.info("Scene phase: background")
        if appLockEnabled {
          BitcoinService.shared.stopAutoSync()
          lockVM.handleBackground()
        }
      case .active:
        logger.info("Scene phase: active")
        showPrivacyScreen = false
        if appLockEnabled {
          lockVM.handleForeground(timeout: lockTimeout)
        }
      case .inactive:
        logger.info("Scene phase: inactive")
      @unknown default:
        break
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
      if appLockEnabled {
        showPrivacyScreen = true
      }
    }
  }
}

// MARK: - Privacy Overlay

private struct PrivacyOverlayView: View {
  var body: some View {
    ZStack {
      Color.hbBackground
        .ignoresSafeArea()

      VStack(spacing: 32) {
        Spacer()

        ThemedAppIcon()
          .aspectRatio(contentMode: .fit)
          .frame(width: 120, height: 120)
          .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .stroke(Color.hbBackground, lineWidth: 24)
              .blur(radius: 12)
              .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
          )

        Text("Birch Wallet")
          .font(.hbDisplay(34))
          .foregroundStyle(Color.hbTextPrimary)

        Spacer()
      }
    }
  }
}

// MARK: - Lock Screen

private struct AppLockView: View {
  @Bindable var lockVM: AppLockViewModel
  let modelContext: ModelContext
  @State private var lockoutTimer: Timer?

  private var biometricIcon: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    switch context.biometryType {
    case .faceID: return "faceid"
    case .touchID: return "touchid"
    case .opticID: return "opticid"
    default: return "lock.fill"
    }
  }

  var body: some View {
    ZStack {
      Color.hbBackground
        .ignoresSafeArea()

      if lockVM.needsPINEntry {
        pinEntryView
      } else {
        biometricView
      }
    }
    .onAppear {
      startLockoutTimerIfNeeded()
    }
    .onDisappear {
      lockoutTimer?.invalidate()
    }
  }

  private var biometricView: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: biometricIcon)
        .font(.system(size: 56))
        .foregroundStyle(Color.hbBitcoinOrange)

      Text(Constants.appName)
        .font(.hbDisplay(28))
        .foregroundStyle(Color.hbTextPrimary)

      Text("Locked")
        .font(.hbBody())
        .foregroundStyle(Color.hbTextSecondary)

      Spacer()

      Button(action: { lockVM.authenticate() }) {
        Text("Unlock")
          .hbPrimaryButton()
      }
      .disabled(lockVM.isAuthenticating)
      .padding(.horizontal, 24)
      .padding(.bottom, 48)
    }
  }

  private var pinEntryView: some View {
    VStack(spacing: 0) {
      Spacer()

      PINPadView(
        title: "Enter PIN",
        subtitle: lockVM.pinError,
        dotCount: lockVM.storedPINLength,
        minDigits: lockVM.storedPINLength,
        mode: .verify,
        pin: $lockVM.pinInput,
        isDisabled: lockVM.isLockedOut,
        onComplete: { pin in
          let success = lockVM.verifyPIN(pin)
          if !success {
            if lockVM.failedAttempts >= 10 {
              lockVM.wipeAllData(modelContext: modelContext)
            }
            startLockoutTimerIfNeeded()
          }
        },
        onFaceIDTap: {
          lockVM.needsPINEntry = false
          lockVM.pinInput = ""
          lockVM.pinError = ""
          lockVM.authenticate()
        }
      )

      Spacer()
    }
    .padding(.horizontal, 16)
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
          lockVM.pinError = ""
        } else {
          lockVM.pinError = lockVM.lockoutRemainingText
        }
      }
    }
  }
}

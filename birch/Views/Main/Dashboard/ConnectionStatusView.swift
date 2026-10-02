import SwiftData
import SwiftUI

struct ConnectionStatusView: View {
  @Environment(\.dismiss) private var dismiss
  @Query private var wallets: [WalletProfile]
  @State private var testResult: String?
  @State private var isTesting = false
  @State private var isSyncing = false
  @State private var copiedDebugInfo = false

  private var service: BitcoinService {
    BitcoinService.shared
  }

  private var activeWallet: WalletProfile? {
    wallets.first(where: { $0.isActive })
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          walletStatusSection
          electrumSection
          syncStatusSection
          actionsSection
        }
        .padding(16)
      }
      .background(Color.hbBackground)
      .navigationTitle("Connection Status")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: true))
        }
        .hbHidesGlassBackground()
      }
    }
  }

  // MARK: - Wallet Status

  private var walletStatusSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Wallet")
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)

      if let wallet = activeWallet {
        HStack {
          Text(wallet.name)
            .font(.hbBody(15))
            .foregroundStyle(Color.hbTextPrimary)
          Spacer()
          NetworkBadge(network: wallet.bitcoinNetwork)
        }

        StatusRow(label: "Loaded", value: service.wallet != nil ? "Yes" : "No",
                  color: service.wallet != nil ? .hbSuccess : .hbError)

        let dbPath = Constants.walletDatabasePath(for: wallet.id).lastPathComponent
        InfoRow(label: "Database", value: dbPath)
      } else {
        Text("No wallet configured")
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .hbCard()
  }

  // MARK: - Electrum Connection

  private var electrumSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Electrum Connection")
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)

      if let wallet = activeWallet {
        let config = wallet.electrumConfig
        InfoRow(label: "Server", value: config.url)
      }

      StatusRow(label: "Connected", value: service.isElectrumConnected ? "Yes" : "No",
                color: service.isElectrumConnected ? .hbSuccess : .hbError)

      if service.chainTipHeight > 0 {
        InfoRow(label: "Chain tip", value: "\(service.chainTipHeight)")
      }

      if let error = service.electrumConnectionError, !service.isElectrumConnected {
        VStack(alignment: .leading, spacing: 4) {
          Text("Connection Error")
            .font(.hbLabel())
            .foregroundStyle(Color.hbError)
          Text(error)
            .font(.hbBody(13))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }

      if let result = testResult {
        Text(result)
          .font(.hbBody(13))
          .foregroundStyle(result.starts(with: "Success") ? Color.hbSuccess : result.starts(with: "Warning") ? Color.hbBitcoinOrange : Color.hbError)
      }
    }
    .hbCard()
  }

  // MARK: - Sync Status

  private var syncStatusSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Refresh Status")
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)

      HStack {
        Text("State")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        Spacer()
        HStack(spacing: 6) {
          SyncStatusDot(state: service.syncState)
          Text(syncStateLabel)
            .font(.hbBody(15))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }

      if let lastSync = service.lastSyncDate {
        InfoRow(label: "Last refresh", value: lastSync.relativeString)
      }

      InfoRow(label: "Last refresh type", value: syncTypeLabel)

      if let error = service.syncState.errorMessage {
        VStack(alignment: .leading, spacing: 4) {
          Text("Error")
            .font(.hbLabel())
            .foregroundStyle(Color.hbError)
          Text(error)
            .font(.hbMono(12))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }
    }
    .hbCard()
  }

  // MARK: - Actions

  private var actionsSection: some View {
    VStack(spacing: 12) {
      Text("Actions")
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: syncNow) {
        HStack(spacing: 8) {
          if isSyncing {
            ProgressView().tint(Color.hbBitcoinOrange)
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
          Text(isSyncing ? "Refreshing..." : "Refresh Now")
            .font(.hbBody(15))
        }
        .foregroundStyle(Color.hbBitcoinOrange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.hbBitcoinOrange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .disabled(isSyncing)

      Button(action: fullResync) {
        HStack(spacing: 8) {
          Image(systemName: "arrow.clockwise")
          Text("Full Refresh")
            .font(.hbBody(15))
        }
        .foregroundStyle(Color.hbError)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.hbError.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .disabled(isSyncing)

      Button(action: testConnection) {
        HStack(spacing: 8) {
          if isTesting {
            ProgressView().tint(Color.hbSteelBlue)
          } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
          }
          Text(isTesting ? "Testing..." : "Test Connection")
            .font(.hbBody(15))
        }
        .foregroundStyle(Color.hbSteelBlue)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.hbSteelBlue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      .disabled(isTesting)

      HBDivider()

      Button(action: copyDebugInfo) {
        HStack(spacing: 8) {
          Image(systemName: copiedDebugInfo ? "checkmark" : "doc.on.doc")
          Text(copiedDebugInfo ? "Copied to Clipboard" : "Copy Debug Info")
            .font(.hbBody(15))
        }
        .foregroundStyle(Color.hbTextSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .birchCard(.nested)
      }
    }
    .hbCard()
  }

  // MARK: - Helpers

  private var syncStateLabel: String {
    switch service.syncState {
    case .notStarted: "Not Started"
    case let .syncing(msg): msg.replacingOccurrences(of: "Syncing", with: "Refreshing")
    case .synced: "Synced"
    case .error: "Error"
    }
  }

  private var syncTypeLabel: String {
    switch service.lastSyncType {
    case .none: "None"
    case .fullScan: "Full Scan"
    case .incremental: "Incremental"
    }
  }

  private func syncNow() {
    isSyncing = true
    Task {
      try? await service.sync()
      isSyncing = false
    }
  }

  private func fullResync() {
    isSyncing = true
    Task {
      try? await service.fullResync()
      isSyncing = false
    }
  }

  private func copyDebugInfo() {
    var lines = ["=== Birch Debug Info ==="]
    lines.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")

    // SwiftData wallet info
    lines.append("\n--- SwiftData Wallets (\(wallets.count)) ---")
    for wallet in wallets {
      lines.append("Name: \(wallet.name)")
      lines.append("ID: \(wallet.id)")
      lines.append("Active: \(wallet.isActive)")
      lines.append("Network: \(wallet.network)")
      lines.append("Type: \(wallet.requiredSignatures)-of-\(wallet.totalCosigners)")
      lines.append("Gap Limit: \(wallet.addressGapLimit)")
      lines.append("External Descriptor: \(wallet.externalDescriptor)")
      lines.append("Internal Descriptor: \(wallet.internalDescriptor)")

      let sorted = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }
      for cosigner in sorted {
        lines.append("  Cosigner[\(cosigner.orderIndex)]: \(cosigner.label)")
        lines.append("    Fingerprint: \(cosigner.fingerprint)")
        lines.append("    DerivationPath: \(cosigner.derivationPath)")
        lines.append("    Xpub: \(cosigner.xpub)")
      }
      lines.append("")
    }

    // BitcoinService state
    lines.append("--- BitcoinService State ---")
    lines.append("currentProfile set: \(service.currentProfile != nil)")
    lines.append("currentProfile ID: \(service.currentProfile?.id.uuidString ?? "nil")")
    lines.append("wallet loaded: \(service.wallet != nil)")
    lines.append("electrumConnected: \(service.isElectrumConnected)")
    lines.append("electrumURL: \(service.electrumURL ?? "nil")")
    lines.append("chainTipHeight: \(service.chainTipHeight)")
    lines.append("syncState: \(syncStateLabel)")
    lines.append("lastSyncType: \(syncTypeLabel)")
    if let date = service.lastSyncDate {
      lines.append("lastSyncDate: \(ISO8601DateFormatter().string(from: date))")
    } else {
      lines.append("lastSyncDate: nil")
    }
    lines.append("balance: \(service.balance)")
    lines.append("transactions: \(service.transactions.count)")

    // Sync Log
    lines.append("\n--- Sync Log (\(service.syncLog.count)) ---")
    for logEntry in service.syncLog {
      lines.append(logEntry)
    }

    // Electrum config from UserDefaults
    if let wallet = activeWallet {
      let config = wallet.electrumConfig
      lines.append("\n--- Electrum Config (Wallet) ---")
      lines.append("URL: \(config.url)")
      lines.append("Host: \(config.host)")
      lines.append("Port: \(config.port)")
      lines.append("SSL: \(config.useSSL)")
    }

    UIPasteboard.general.string = lines.joined(separator: "\n")
    copiedDebugInfo = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      copiedDebugInfo = false
    }
  }

  private func testConnection() {
    guard let wallet = activeWallet else {
      testResult = "No wallet configured"
      return
    }
    isTesting = true
    testResult = nil
    Task {
      let config = wallet.electrumConfig
      do {
        let height = try await service.testElectrumConnection(config: config)
        let network = wallet.bitcoinNetwork
        if network != .signet {
          if let detected = try? await service.detectElectrumNetwork(config: config),
             detected != network
          {
            testResult = "Warning: Server is \(detected.displayName), expected \(network.displayName)"
            isTesting = false
            return
          }
        }
        testResult = "Success — \(network.displayName) Chain Tip Height \(height)"
      } catch {
        testResult = "Failed: \(BitcoinService.friendlyElectrumError(error))"
      }
      isTesting = false
    }
  }
}

// MARK: - Status Row

private struct StatusRow: View {
  let label: String
  let value: String
  let color: Color

  var body: some View {
    HStack {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      Spacer()
      HStack(spacing: 6) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
        Text(value)
          .font(.hbBody(15))
          .foregroundStyle(Color.hbTextPrimary)
      }
    }
  }
}

private struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      Spacer()
      Text(value)
        .font(.hbBody(15))
        .foregroundStyle(Color.hbTextPrimary)
    }
  }
}

import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import URKit

private let logger = AppLog(.wallet)

struct WalletInfoView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Bindable var wallet: WalletProfile
  @State private var gapLimitText: String = ""
  @State private var isResyncing = false
  @State private var resyncError: String?
  @State private var resyncSuccess = false
  @State private var showEditCosigners = false
  @State private var isEditingName = false
  @State private var editedName: String = ""
  @FocusState private var nameFieldFocused: Bool
  @State private var electrumHostText: String = ""
  @State private var electrumPortText: String = ""
  @State private var isTestingConnection = false
  @State private var connectionTestResult: String?
  @State private var blockExplorerText: String = ""
  @State private var initialElectrumConfig: ElectrumConfig?
  @State private var showInsecureSSLAlert = false
  @State private var showDescriptorQR = false
  @State private var showDeleteConfirmation = false
  @State private var showResetElectrumConfirmation = false
  @State private var showDescriptorPDF = false

  /// The output descriptor rebuilt from the saved cosigners, or nil when one of
  /// their keys is not a valid extended public key.
  private var combinedDescriptor: String? {
    let cosignerData = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }.map {
      (xpub: $0.xpub, fingerprint: $0.fingerprint, derivationPath: $0.derivationPath)
    }
    return try? BitcoinService.buildCombinedDescriptor(
      requiredSignatures: wallet.requiredSignatures,
      cosigners: cosignerData,
      network: wallet.bitcoinNetwork,
    )
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        let exportDescriptor = combinedDescriptor

        // Overview
        VStack(spacing: 12) {
          // Editable name row
          HStack {
            Text("Name")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            Spacer()
            if isEditingName {
              TextField("Wallet name", text: $editedName)
                .font(.hbBody(15))
                .foregroundStyle(Color.hbTextPrimary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 180)
                .focused($nameFieldFocused)
                .onSubmit { saveName() }
                .onAppear { nameFieldFocused = true }
              Button(action: saveName) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(Color.hbSuccess)
              }
            } else {
              Text(wallet.name)
                .font(.hbBody(15))
                .foregroundStyle(Color.hbTextPrimary)
              Button(action: {
                editedName = wallet.name
                isEditingName = true
              }) {
                Image(systemName: "pencil")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.hbSteelBlue)
              }
            }
          }
          InfoRow(label: "Type", value: wallet.multisigDescription + " Multisig")
          InfoRow(label: "Network", value: wallet.bitcoinNetwork.displayName)
          InfoRow(label: "Script", value: "P2WSH (Native Segwit)")
          InfoRow(label: "Created", value: wallet.createdAt.shortString)
        }
        .hbCard()

        // Descriptor QR
        Button(action: { showDescriptorQR = true }) {
          HStack(spacing: 8) {
            Image(systemName: "qrcode")
            Text("Show Output Descriptor QR")
              .font(.hbBody(15))
          }
          .foregroundStyle(Color.hbBitcoinOrange)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.hbBitcoinOrange.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(exportDescriptor == nil)
        .opacity(exportDescriptor == nil ? 0.5 : 1)

        // Copy descriptor
        Button(action: {
          if let exportDescriptor {
            UIPasteboard.general.string = exportDescriptor
          }
        }) {
          HStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
            Text("Copy Output Descriptor")
              .font(.hbBody(15))
          }
          .foregroundStyle(Color.hbSteelBlue)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.hbSteelBlue.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(exportDescriptor == nil)
        .opacity(exportDescriptor == nil ? 0.5 : 1)

        // Descriptor PDF
        Button(action: { showDescriptorPDF = true }) {
          HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
            Text("PDF/Print Output Descriptor")
              .font(.hbBody(15))
          }
          .foregroundStyle(Color.purple)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.purple.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .disabled(exportDescriptor == nil)
        .opacity(exportDescriptor == nil ? 0.5 : 1)

        if exportDescriptor == nil {
          Text("The output descriptor can't be exported: a saved cosigner key is not a valid extended public key. Use Edit under Cosigners to correct it.")
            .font(.hbLabel())
            .foregroundStyle(Color.hbError)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Cosigners
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Cosigners")
              .font(.hbHeadline)
              .foregroundStyle(Color.hbTextPrimary)
            Spacer()
            Button(action: { showEditCosigners = true }) {
              Text("Edit")
                .font(.hbBody(15))
                .foregroundStyle(Color.hbBitcoinOrange)
            }
            .accessibilityIdentifier("editCosigners")
          }

          let sorted = (wallet.cosigners).sorted { $0.orderIndex < $1.orderIndex }
          ForEach(sorted) { cosigner in
            CosignerCardView(cosigner: cosigner)
          }
        }
        .hbCard()

        // Electrum Server
        VStack(spacing: 12) {
          Text("Electrum Server")
            .font(.hbHeadline)
            .foregroundStyle(Color.hbTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading, spacing: 6) {
            Text("Host")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            TextField(wallet.bitcoinNetwork.defaultElectrumHost ?? "Enter server host", text: $electrumHostText)
              .font(.hbMono(14))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .padding(10)
              .birchCard(.nested)
              .foregroundStyle(Color.hbTextPrimary)
              .onChange(of: electrumHostText) {
                wallet.electrumHost = electrumHostText.trimmingCharacters(in: .whitespaces)
              }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Port")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            TextField("\(wallet.bitcoinNetwork.defaultElectrumPort)", text: $electrumPortText)
              .font(.hbMono(14))
              .keyboardType(.numberPad)
              .padding(10)
              .birchCard(.nested)
              .foregroundStyle(Color.hbTextPrimary)
              .onChange(of: electrumPortText) { old, new in
                let accepted = InputLimits.sanitizeCount(new, old: old, max: InputLimits.maxPort)
                if accepted != new {
                  // Not a port number — ignore the keystroke
                  electrumPortText = accepted
                  return
                }
                wallet.electrumPort = Int(accepted) ?? 0
              }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Protocol")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            Picker("Protocol", selection: Binding(
              get: {
                switch wallet.electrumSSL {
                case 1: 1 // TCP
                case 2: 2 // SSL
                default: wallet.bitcoinNetwork.usesSSL ? 2 : 1
                }
              },
              set: {
                wallet.electrumSSL = $0
                if $0 != 2 {
                  wallet.electrumAllowInsecureSSL = false
                }
              },
            )) {
              Text("TCP").tag(1)
              Text("SSL").tag(2)
            }
            .pickerStyle(.segmented)
          }

          if wallet.electrumSSL == 2 || (wallet.electrumSSL == 0 && wallet.bitcoinNetwork.usesSSL) {
            Toggle(isOn: Binding(
              get: { wallet.electrumAllowInsecureSSL },
              set: { newValue in
                if newValue {
                  showInsecureSSLAlert = true
                } else {
                  wallet.electrumAllowInsecureSSL = false
                }
              },
            )) {
              Text("Allow insecure SSL")
                .font(.hbBody(13))
                .foregroundStyle(Color.hbTextPrimary)
            }
            .tint(Color.hbBitcoinOrange)
          }

          if let result = connectionTestResult {
            Text(result)
              .font(.hbBody(13))
              .foregroundStyle(result.starts(with: "Success") ? Color.hbSuccess : result.starts(with: "Warning") ? Color.hbBitcoinOrange : Color.hbError)
          }

          HStack(spacing: 12) {
            Button(action: testElectrumConnection) {
              HStack(spacing: 6) {
                if isTestingConnection {
                  ProgressView().tint(Color.hbSteelBlue)
                } else {
                  Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Text(isTestingConnection ? "Testing..." : "Test Connection")
                  .font(.hbBody(14))
              }
              .foregroundStyle(Color.hbSteelBlue)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(Color.hbSteelBlue.opacity(0.12))
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .disabled(isTestingConnection)

            Button(action: { showResetElectrumConfirmation = true }) {
              HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset")
                  .font(.hbBody(14))
              }
              .foregroundStyle(Color.hbTextSecondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .birchCard(.nested)
            }
          }
        }
        .hbCard()
        .alert("Reset Electrum Server?", isPresented: $showResetElectrumConfirmation) {
          Button("Cancel", role: .cancel) {}
          Button("Reset", role: .destructive) {
            resetElectrumDefaults()
          }
        } message: {
          Text("This will clear custom host, port, and protocol settings and revert to network defaults.")
        }

        // Block Explorer
        VStack(spacing: 12) {
          Text("Block Explorer")
            .font(.hbHeadline)
            .foregroundStyle(Color.hbTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading, spacing: 6) {
            Text("Host")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
            TextField("mempool.space", text: $blockExplorerText)
              .font(.hbMono(14))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .padding(10)
              .birchCard(.nested)
              .foregroundStyle(Color.hbTextPrimary)
              .onChange(of: blockExplorerText) {
                wallet.blockExplorerHost = blockExplorerText.trimmingCharacters(in: .whitespaces)
              }

            Text("Uses mempool.space-compatible URL format: host/tx/, host/address/")
              .font(.hbBody(12))
              .foregroundStyle(Color.hbTextSecondary)
          }
        }
        .hbCard()

        // Gap Limit & Resync
        VStack(spacing: 16) {
          Text("Refresh Settings")
            .font(.hbHeadline)
            .foregroundStyle(Color.hbTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)

          VStack(alignment: .leading, spacing: 6) {
            Text("Address Gap Limit")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)

            HStack(spacing: 8) {
              TextField("50", text: $gapLimitText)
                .font(.hbMono(16))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 80)
                .padding(10)
                .birchCard(.nested)
                .foregroundStyle(Color.hbTextPrimary)
                .onChange(of: gapLimitText) { old, new in
                  let accepted = InputLimits.sanitizeCount(new, old: old, max: InputLimits.maxGapLimit)
                  if accepted != new {
                    // Out of range or not a whole number — ignore the keystroke
                    gapLimitText = accepted
                    return
                  }
                  if let value = Int(accepted) {
                    wallet.addressGapLimit = value
                  }
                }

              Text("addresses")
                .font(.hbBody(14))
                .foregroundStyle(Color.hbTextSecondary)
            }

            Text("Number of consecutive unused addresses to scan. Increase if funds are missing.")
              .font(.hbBody(12))
              .foregroundStyle(Color.hbTextSecondary)
          }

          HBDivider()

          VStack(spacing: 12) {
            Button(action: forceResync) {
              HStack(spacing: 8) {
                if isResyncing {
                  ProgressView()
                    .tint(Color.hbBitcoinOrange)
                } else {
                  Image(systemName: "arrow.clockwise")
                }
                Text(isResyncing ? "Refreshing..." : "Force Full Refresh")
                  .font(.hbBody(15))
              }
              .foregroundStyle(Color.hbBitcoinOrange)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Color.hbBitcoinOrange.opacity(0.12))
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(isResyncing)

            Text("Refreshes all addresses from scratch using the gap limit above. This may take a while.")
              .font(.hbBody(12))
              .foregroundStyle(Color.hbTextSecondary)

            if resyncSuccess {
              Label("Refresh complete", systemImage: "checkmark.circle.fill")
                .font(.hbBody(14))
                .foregroundStyle(Color.hbSuccess)
            }

            if let error = resyncError {
              Text(error)
                .font(.hbBody(13))
                .foregroundStyle(Color.hbError)
            }
          }
        }
        .hbCard()

        // Wallet Labels: exporting reads the loaded wallet's transactions,
        // UTXOs and addresses, so the card is only offered for that wallet
        if BitcoinService.shared.currentProfile?.id == wallet.id {
          WalletLabelsCard(wallet: wallet)
        }

        // Privacy Mode
        VStack(spacing: 12) {
          Toggle(isOn: Binding(
            get: { wallet.privacyMode },
            set: { new in
              logger.info("Privacy mode \(new ? "enabled" : "disabled")")
              wallet.privacyMode = new
            },
          )) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Privacy Mode")
                .foregroundStyle(Color.hbTextPrimary)
              Text("Hide balances, addresses, and transaction details")
                .font(.hbBody(12))
                .foregroundStyle(Color.hbTextSecondary)
            }
          }
          .tint(Color.hbBitcoinOrange)
        }
        .hbCard()

        // Delete Wallet
        Button(action: { showDeleteConfirmation = true }) {
          HStack(spacing: 8) {
            Image(systemName: "trash")
            Text("Delete Wallet")
              .font(.hbBody(15))
          }
          .foregroundStyle(Color.hbError)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.hbError.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.top, 16)
      }
      .padding(16)
    }
    .scrollDismissesKeyboard(.interactively)
    .alert("Delete Wallet", isPresented: $showDeleteConfirmation) {
      Button("Delete", role: .destructive) { deleteWallet() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Are you sure you want to delete \"\(wallet.name)\"? This cannot be undone. You can re-import using your output descriptor.")
    }
    .onTapGesture {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    .background(Color.hbBackground)
    .navigationTitle("Wallet Settings")
    .onAppear {
      gapLimitText = "\(wallet.scanGapLimit)"
      electrumHostText = wallet.electrumHost
      electrumPortText = wallet.customElectrumPort.map { "\($0)" } ?? ""
      blockExplorerText = wallet.blockExplorerHost
      initialElectrumConfig = wallet.electrumConfig
    }
    .onDisappear {
      if let initial = initialElectrumConfig, wallet.electrumConfig != initial {
        logger.info("Electrum settings changed — reloading wallet")
        let service = BitcoinService.shared
        Task {
          service.unloadWallet()
          try? await service.loadWallet(profile: wallet)
          try? await service.sync()
        }
      }
    }
    .alert("Allow Insecure SSL?", isPresented: $showInsecureSSLAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Allow", role: .destructive) {
        wallet.electrumAllowInsecureSSL = true
      }
    } message: {
      Text("This removes the requirement to verify that the server is who it claims to be. The connection will still be encrypted, but self-signed, expired, or invalid certificates will be accepted.")
    }
    .sheet(isPresented: $showEditCosigners) {
      EditCosignersView(wallet: wallet)
        .birchSheet()
    }
    .sheet(isPresented: $showDescriptorQR) {
      DescriptorQRSheet(descriptor: combinedDescriptor ?? "", walletName: wallet.name)
        .birchSheet()
    }
    .sheet(isPresented: $showDescriptorPDF) {
      DescriptorPDFView(walletName: wallet.name, descriptor: combinedDescriptor ?? "")
        .birchSheet()
    }
  }

  private func testElectrumConnection() {
    isTestingConnection = true
    connectionTestResult = nil
    let config = wallet.electrumConfig
    logger.info("Testing Electrum connection to \(config.url)")
    Task {
      do {
        let height = try await BitcoinService.shared.testElectrumConnection(config: config)
        logger.info("Electrum connection test succeeded")
        let network = wallet.bitcoinNetwork
        if network != .signet {
          if let detected = try? await BitcoinService.shared.detectElectrumNetwork(config: config),
             detected != network
          {
            connectionTestResult = "Warning: Server is \(detected.displayName), expected \(network.displayName)"
            isTestingConnection = false
            return
          }
        }
        connectionTestResult = "Success — \(network.displayName) Chain Tip Height \(height)"
      } catch {
        logger.error("Electrum connection test failed: \(error)")
        connectionTestResult = "Failed: \(error.localizedDescription)"
      }
      isTestingConnection = false
    }
  }

  private func resetElectrumDefaults() {
    logger.info("Electrum config reset to defaults")
    wallet.electrumHost = ""
    wallet.electrumPort = 0
    wallet.electrumSSL = 0
    wallet.electrumAllowInsecureSSL = false
    electrumHostText = ""
    electrumPortText = ""
    connectionTestResult = nil
  }

  private func saveName() {
    let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      logger.info("Wallet name changed to \(trimmed)")
      wallet.name = trimmed
    }
    isEditingName = false
  }

  private func forceResync() {
    logger.info("Force full resync initiated")
    isResyncing = true
    resyncError = nil
    resyncSuccess = false

    Task {
      do {
        try await BitcoinService.shared.fullResync()
        logger.info("Force resync completed")
        resyncSuccess = true
      } catch {
        logger.error("Force resync failed: \(error)")
        resyncError = error.localizedDescription
      }
      isResyncing = false
    }
  }

  private func deleteWallet() {
    let walletManager = WalletManagerViewModel()
    walletManager.deleteWallet(wallet, modelContext: modelContext)
    dismiss()
  }
}

// MARK: - Wallet Labels Card

/// BIP 329 label import and export, by file or QR, for the loaded wallet
private struct WalletLabelsCard: View {
  @Environment(\.modelContext) private var modelContext
  let wallet: WalletProfile
  @State private var showImportFilePicker = false
  @State private var showImportQRScanner = false
  @State private var showExportQR = false
  @State private var importResult: String?
  @State private var showImportResult = false

  var body: some View {
    VStack(spacing: 12) {
      Text("Wallet Labels")
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text("Import or export transaction, address, UTXO and cosigner labels in BIP 329 format.")
        .font(.hbBody(12))
        .foregroundStyle(Color.hbTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 12) {
        HBTonalButton(title: "Import File", systemImage: "square.and.arrow.down") {
          showImportFilePicker = true
        }
        HBTonalButton(title: "Export File", systemImage: "square.and.arrow.up", neutral: true, action: exportLabelsToFile)
      }

      HStack(spacing: 12) {
        HBTonalButton(title: "Import QR", systemImage: "qrcode.viewfinder") {
          showImportQRScanner = true
        }
        HBTonalButton(title: "Export QR", systemImage: "qrcode", neutral: true) {
          showExportQR = true
        }
      }
    }
    .hbCard()
    .fileImporter(
      isPresented: $showImportFilePicker,
      allowedContentTypes: [UTType(filenameExtension: "jsonl") ?? .plainText],
      allowsMultipleSelection: false,
    ) { result in
      importLabelsFromFile(result: result)
    }
    .alert("Import Labels", isPresented: $showImportResult) {
      Button("OK", role: .cancel) {}
    } message: {
      if let importResult {
        Text(importResult)
      }
    }
    .sheet(isPresented: $showImportQRScanner) {
      URScannerSheet(expectedTypes: [.rawBytes], onCancel: { showImportQRScanner = false }) { result in
        handleQRImportResult(result)
      }
      .birchSheet()
    }
    .sheet(isPresented: $showExportQR) {
      LabelsQRSheet(buildExport: buildExportData)
        .birchSheet()
    }
  }

  private func buildExportData() -> Data {
    let service = BitcoinService.shared
    let walletID = wallet.id
    let frozenDescriptor = FetchDescriptor<FrozenUTXO>(predicate: #Predicate { $0.walletID == walletID })
    let frozenOutpoints = Set(((try? modelContext.fetch(frozenDescriptor)) ?? []).map(\.outpoint))

    return LabelService.exportBIP329(
      walletID: walletID,
      context: modelContext,
      transactions: service.transactions,
      utxos: service.utxos,
      frozenOutpoints: frozenOutpoints,
      receiveAddresses: service.getAddresses(keychain: .external),
      changeAddresses: service.getAddresses(keychain: .internal),
      cosigners: wallet.cosigners,
      requiredSignatures: wallet.requiredSignatures,
      network: wallet.bitcoinNetwork,
    )
  }

  private func exportLabelsToFile() {
    let data = buildExportData()
    let sanitizedName = wallet.name.replacingOccurrences(of: " ", with: "-")
    let fileName = "\(sanitizedName)-labels.jsonl"
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    try? data.write(to: tempURL)

    let activityVC = UIActivityViewController(
      activityItems: [tempURL],
      applicationActivities: nil,
    )
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          var topVC = windowScene.windows.first?.rootViewController else { return }
    while let presented = topVC.presentedViewController {
      topVC = presented
    }
    if let popover = activityVC.popoverPresentationController {
      popover.sourceView = topVC.view
      popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: 0, width: 0, height: 0)
    }
    topVC.present(activityVC, animated: true)
  }

  private func importLabelsFromFile(result: Result<[URL], Error>) {
    switch result {
    case let .success(urls):
      guard let url = urls.first else { return }
      guard url.startAccessingSecurityScopedResource() else {
        importResult = "Unable to access the selected file."
        showImportResult = true
        return
      }
      defer { url.stopAccessingSecurityScopedResource() }

      guard let data = try? Data(contentsOf: url) else {
        importResult = "Unable to read the selected file."
        showImportResult = true
        return
      }
      importLabels(data, fromQR: false)

    case .failure:
      importResult = "Failed to select a file."
      showImportResult = true
    }
  }

  private func handleQRImportResult(_ result: AppURResult) {
    showImportQRScanner = false

    guard case let .rawBytes(data) = result else {
      importResult = "Unexpected QR code type. Expected UR-encoded labels."
      showImportResult = true
      return
    }
    importLabels(data, fromQR: true)
  }

  private func importLabels(_ data: Data, fromQR: Bool) {
    do {
      let count = try LabelService.importBIP329(
        data: data,
        walletID: wallet.id,
        cosigners: wallet.cosigners,
        context: modelContext,
      )

      if count == 0 {
        importResult = "No new labels found to import."
      } else {
        importResult = "Successfully imported \(count) label\(count == 1 ? "" : "s")."
      }
    } catch {
      logger.error("Failed to save imported labels\(fromQR ? " from QR" : ""): \(error.localizedDescription)")
      importResult = "Failed to save imported labels."
    }
    showImportResult = true
  }
}

// MARK: - Labels QR Sheet

/// The wallet's BIP 329 labels as an animated `ur:bytes` QR
struct LabelsQRSheet: View {
  /// Bytes per UR fragment. The Sparrow labels harness encodes with the same value.
  static let maxFragmentLen = 400

  let buildExport: () -> Data
  @Environment(\.dismiss) private var dismiss
  @State private var exportData: Data?

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        VStack(spacing: 16) {
          if let exportData {
            URDisplaySheet(data: exportData, urType: "bytes", maxFragmentLen: Self.maxFragmentLen)
              .padding(5)
              .background(Color.white)
              .shadow(color: Color.hbBitcoinOrange.opacity(0.2), radius: 20)
          } else {
            VStack(spacing: 12) {
              ProgressView()
                .tint(Color.hbBitcoinOrange)
                .scaleEffect(1.5)
              Text("Preparing labels...")
                .font(.hbBody(14))
                .foregroundStyle(Color.hbTextSecondary)
            }
          }

          Text("Scan to import wallet labels")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .padding(24)
      }
      .navigationTitle("Export Labels")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: true))
        }
        .hbHidesGlassBackground()
      }
    }
    .task {
      if exportData == nil {
        exportData = buildExport()
      }
    }
  }
}

// MARK: - Edit Cosigners Sheet

/// Edit Cosigners: the Import cosigners form (`CosignerForm`) filled in from the
/// wallet, with Cancel and Save. Renaming saves straight away; changing a
/// key, fingerprint or path rebuilds the wallet, so it asks first.
private struct EditCosignersView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Bindable var wallet: WalletProfile
  @State private var form: SetupWizardViewModel
  @State private var saveError: String?
  @State private var showChangeKeysConfirmation = false

  private static let topID = "edit-cosigners-top"

  init(wallet: WalletProfile) {
    self.wallet = wallet
    _form = State(initialValue: SetupWizardViewModel.forEditing(wallet))
  }

  private var edited: [(label: String, xpub: String, fingerprint: String, derivationPath: String)] {
    (0 ..< form.totalCosigners).map {
      (
        label: form.cosignerLabels[$0],
        xpub: form.cosignerXpubs[$0],
        fingerprint: form.cosignerFingerprints[$0],
        derivationPath: form.cosignerDerivationPaths[$0],
      )
    }
  }

  private var hasChanges: Bool {
    WalletManagerViewModel.cosignerChange(of: wallet, to: edited) != .none
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 24) {
          Text("Edit Cosigners")
            .font(.hbDisplay(28))
            .foregroundStyle(Color.hbTextPrimary)
            .id(Self.topID)

          CosignerForm(viewModel: form)
            .padding(.horizontal, 24)

          if let saveError {
            Text(saveError)
              .font(.hbLabel())
              .foregroundStyle(Color.hbError)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 24)
          }

          HStack(spacing: 16) {
            Button(action: { dismiss() }) {
              Text("Cancel")
                .hbCompactSecondaryButton()
            }

            Spacer()

            // Outlined until every cosigner is complete, but never disabled:
            // Save is what shows the user what is missing
            Button(action: { save(proxy: proxy) }) {
              Text("Save")
                .hbCompactPrimaryButton(form.allCosignersComplete ? .filled : .outlined)
            }
          }
          .padding(.horizontal, 24)
          .padding(.bottom, 32)
        }
        .padding(.top, 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismissKeyboard)
      }
      .scrollDismissesKeyboard(.interactively)
    }
    .background(Color.hbBackground)
    // A swipe down would throw away the edits; Cancel still can
    .interactiveDismissDisabled(hasChanges)
    .alert("Change Cosigner Keys?", isPresented: $showChangeKeysConfirmation) {
      Button("Change Keys", role: .destructive) { commit() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This rebuilds the wallet from the new cosigner details. Birch clears its downloaded transactions and UTXOs and refreshes from scratch. A changed key gives the wallet different addresses, so labels and frozen coins on the current transactions, addresses and UTXOs won't match anything, and saved PSBTs can't be signed. Export your labels and output descriptor first if you might need them.")
    }
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  /// Save: shows what is missing like Next does, then saves according to
  /// what changed
  private func save(proxy: ScrollViewProxy) {
    dismissKeyboard()
    let action = form.checkCosigners()
    guard action == .finish else {
      CosignerForm.reveal(action, viewModel: form, proxy: proxy, topID: Self.topID)
      return
    }

    switch WalletManagerViewModel.cosignerChange(of: wallet, to: edited) {
    case .none:
      dismiss()
    case .detailsOnly:
      commit()
    case .keys:
      showChangeKeysConfirmation = true
    }
  }

  private func commit() {
    let walletManager = WalletManagerViewModel()
    guard walletManager.updateCosigners(of: wallet, to: edited, modelContext: modelContext) else {
      saveError = walletManager.errorMessage
      return
    }
    saveError = nil
    dismiss()
  }
}

// MARK: - Descriptor QR Sheet

private struct DescriptorQRSheet: View {
  let descriptor: String
  let walletName: String
  let descriptorUR: UR?
  @Environment(\.dismiss) private var dismiss
  @State private var isExporting = false
  @AppStorage(Constants.qrFrameRateKey) private var qrFrameRate: Double = 3.0

  init(descriptor: String, walletName: String) {
    self.descriptor = descriptor
    self.walletName = walletName
    descriptorUR = try? URService.encodeCryptoOutput(descriptor: descriptor)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        VStack(spacing: 16) {
          if let ur = descriptorUR {
            URDisplaySheet(ur: ur)
              .padding(5)
              .background(Color.white)
              .shadow(color: Color.hbBitcoinOrange.opacity(0.2), radius: 20)
          } else {
            Text("Failed to encode descriptor")
              .font(.hbBody())
              .foregroundStyle(Color.hbError)
          }

          Text("Scan to import this wallet descriptor")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbTextSecondary)
            .multilineTextAlignment(.center)

          Button(action: { exportAsMP4() }) {
            if isExporting {
              HStack(spacing: 8) {
                ProgressView()
                  .tint(Color.hbSteelBlue)
                Text("Generating video...")
                  .font(.hbBody(14))
                  .foregroundStyle(Color.hbSteelBlue)
              }
            } else {
              Label("Export Descriptor as MP4", systemImage: "film")
                .font(.hbBody(14))
                .foregroundStyle(Color.hbSteelBlue)
            }
          }
          .disabled(isExporting || descriptorUR == nil)
        }
        .padding(.top, 8)
      }
      .navigationTitle("Wallet Descriptor")
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

  private func exportAsMP4() {
    guard let ur = descriptorUR else { return }
    isExporting = true
    Task {
      do {
        let url = try await QRVideoExporter.exportMP4(
          ur: ur,
          fileName: "\(walletName) Output Descriptor",
          maxFragmentLen: 160,
          fps: qrFrameRate,
          loopCount: 3,
        )
        await MainActor.run {
          isExporting = false
          presentShareSheet(url: url)
        }
      } catch {
        await MainActor.run {
          isExporting = false
        }
      }
    }
  }

  private func presentShareSheet(url: URL) {
    let activityVC = UIActivityViewController(
      activityItems: [url],
      applicationActivities: nil,
    )
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          var topVC = windowScene.windows.first?.rootViewController else { return }
    while let presented = topVC.presentedViewController {
      topVC = presented
    }
    if let popover = activityVC.popoverPresentationController {
      popover.sourceView = topVC.view
      popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: 0, width: 0, height: 0)
    }
    topVC.present(activityVC, animated: true)
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

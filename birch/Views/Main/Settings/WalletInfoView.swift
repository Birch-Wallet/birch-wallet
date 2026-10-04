import SwiftData
import SwiftUI
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
      network: wallet.bitcoinNetwork
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
              Label("Edit", systemImage: "pencil")
                .font(.hbLabel())
                .foregroundStyle(Color.hbBitcoinOrange)
            }
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
              .onChange(of: electrumPortText) {
                wallet.electrumPort = Int(electrumPortText) ?? 0
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
              }
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
              }
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
                .onChange(of: gapLimitText) {
                  if let value = Int(gapLimitText), value > 0 {
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

        // Privacy Mode
        VStack(spacing: 12) {
          Toggle(isOn: Binding(
            get: { wallet.privacyMode },
            set: { new in
              logger.info("Privacy mode \(new ? "enabled" : "disabled")")
              wallet.privacyMode = new
            }
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
      gapLimitText = "\(wallet.addressGapLimit)"
      electrumHostText = wallet.electrumHost
      electrumPortText = wallet.electrumPort > 0 ? "\(wallet.electrumPort)" : ""
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

// MARK: - Edit Cosigners Sheet

private struct EditCosignersView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Bindable var wallet: WalletProfile
  @State private var editableCosigners: [EditableCosigner] = []
  @State private var currentIndex: Int = 0
  @State private var validationError: String?
  @State private var showScanner = false
  @State private var showSaveConfirmation = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          // Cosigner tabs
          HStack(spacing: 8) {
            ForEach(editableCosigners.indices, id: \.self) { index in
              Button(action: { currentIndex = index }) {
                VStack(spacing: 4) {
                  ZStack {
                    Color.clear
                      .frame(height: 44)
                      .birchSelected(index == currentIndex)
                    Image(systemName: "person.badge.key.fill")
                      .font(.system(size: 14))
                      .foregroundStyle(index == currentIndex ? Color.hbBitcoinOrange : Color.hbTextSecondary)
                  }
                  Text("\(index + 1)")
                    .font(.hbLabel(11))
                    .foregroundStyle(index == currentIndex ? Color.hbBitcoinOrange : Color.hbTextSecondary)
                }
              }
            }
          }
          .padding(.horizontal, 16)

          if editableCosigners.indices.contains(currentIndex) {
            cosignerForm(for: currentIndex)
          }

          if let error = validationError {
            Text(error)
              .font(.hbLabel())
              .foregroundStyle(Color.hbError)
              .padding(.horizontal, 16)
          }

          // Save button
          Button(action: { showSaveConfirmation = true }) {
            Text("Save Changes")
              .font(.hbHeadline)
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Color.hbBitcoinOrange)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 32)
        }
        .padding(.top, 16)
      }
      .scrollDismissesKeyboard(.interactively)
      .onTapGesture {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      }
      .background(Color.hbBackground)
      .navigationTitle("Edit Cosigners")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: false))
        }
        .hbHidesGlassBackground()
      }
      .sheet(isPresented: $showScanner) {
        URScannerSheet(expectedTypes: [.hdKey], onCancel: { showScanner = false }) { result in
          handleScanResult(result)
          showScanner = false
        }
        .birchSheet()
      }
      .alert("Save Changes?", isPresented: $showSaveConfirmation) {
        Button("Save", role: .destructive) { saveChanges() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will update the wallet descriptors and require a full refresh. Any existing wallet data will be cleared.")
      }
    }
    .onAppear { loadCosigners() }
  }

  private func cosignerForm(for index: Int) -> some View {
    VStack(spacing: 16) {
      // Label
      VStack(alignment: .leading, spacing: 6) {
        Text("Label")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        TextField("Cosigner name", text: $editableCosigners[index].label)
          .font(.hbBody())
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)
      }

      // Fingerprint
      VStack(alignment: .leading, spacing: 6) {
        Text("Master Fingerprint (8 hex chars)")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        TextField("e.g. 73c5da0a", text: $editableCosigners[index].fingerprint)
          .font(.hbMono())
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)
      }

      // Derivation path
      VStack(alignment: .leading, spacing: 6) {
        Text("Derivation Path")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        Text(editableCosigners[index].derivationPath.isEmpty ? "–" : editableCosigners[index].derivationPath)
          .font(.hbMono())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)
      }

      // Xpub
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Extended Public Key")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)

          Spacer()

          Button(action: {
            let current = editableCosigners[index].xpub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !current.isEmpty else { return }
            let isTestnet = wallet.bitcoinNetwork != .mainnet
            if let toggled = URService.toggleXpubFormat(current, isTestnet: isTestnet) {
              editableCosigners[index].xpub = toggled
            }
          }) {
            Image(systemName: "arrow.left.arrow.right")
              .font(.system(size: 14, weight: .bold))
              .foregroundStyle(Color.green)
          }
          .padding(.trailing, 12)

          Button(action: {
            if let text = UIPasteboard.general.string {
              let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
              let isTestnet = wallet.bitcoinNetwork != .mainnet
              if let normalized = URService.normalizeXpub(raw, isTestnet: isTestnet) {
                editableCosigners[index].xpub = normalized
              } else {
                editableCosigners[index].xpub = raw
              }
            }
          }) {
            Label("Paste", systemImage: "doc.on.clipboard")
              .font(.hbLabel())
              .foregroundStyle(Color.hbSteelBlue)
          }
        }

        TextEditor(text: $editableCosigners[index].xpub)
          .font(.hbMono(12))
          .frame(minHeight: 80)
          .scrollContentBackground(.hidden)
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)

        Button(action: { showScanner = true }) {
          Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            .font(.hbBody(15))
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
    }
    .hbCard()
    .padding(.horizontal, 16)
  }

  private func loadCosigners() {
    let sorted = wallet.cosigners.sorted { $0.orderIndex < $1.orderIndex }
    editableCosigners = sorted.map { cosigner in
      EditableCosigner(
        id: cosigner.id,
        label: cosigner.label,
        xpub: cosigner.xpub,
        fingerprint: cosigner.fingerprint,
        derivationPath: cosigner.derivationPath,
        orderIndex: cosigner.orderIndex
      )
    }
  }

  private func handleScanResult(_ result: AppURResult) {
    switch result {
    case .hdKey(var xpub, let fingerprint, let derivationPath):
      // Validate derivation path network before accepting the scan
      if !derivationPath.isEmpty {
        if let error = SetupWizardViewModel.validateDerivationPath(derivationPath, for: wallet.bitcoinNetwork) {
          validationError = error
          return
        }
      }

      let isTestnet = wallet.bitcoinNetwork != .mainnet
      if let normalized = URService.normalizeXpub(xpub, isTestnet: isTestnet) {
        xpub = normalized
      }

      guard editableCosigners.indices.contains(currentIndex) else { return }
      editableCosigners[currentIndex].xpub = xpub
      if !fingerprint.isEmpty {
        editableCosigners[currentIndex].fingerprint = fingerprint
      }
      if !derivationPath.isEmpty {
        editableCosigners[currentIndex].derivationPath = derivationPath
      }
    default:
      validationError = "Unexpected QR code type. Expected crypto-hdkey or crypto-account."
    }
  }

  private func saveChanges() {
    let walletManager = WalletManagerViewModel()
    let edited = editableCosigners.map {
      (label: $0.label, xpub: $0.xpub, fingerprint: $0.fingerprint, derivationPath: $0.derivationPath)
    }
    guard walletManager.updateCosigners(of: wallet, to: edited, modelContext: modelContext) else {
      validationError = walletManager.errorMessage
      return
    }

    validationError = nil
    dismiss()
  }
}

private struct EditableCosigner: Identifiable {
  let id: UUID
  var label: String
  var xpub: String
  var fingerprint: String
  var derivationPath: String
  var orderIndex: Int
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
          loopCount: 3
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
      applicationActivities: nil
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

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private let logger = AppLog(.transactions)

struct TransactionListView: View {
  @Query private var wallets: [WalletProfile]
  @Query private var walletLabels: [WalletLabel]
  @Query private var frozenUTXOs: [FrozenUTXO]
  @State private var viewModel = TransactionListViewModel()
  @State private var walletManager = WalletManagerViewModel()
  @State private var showWalletPicker = false
  @State private var walletPickerEditMode = false
  @State private var showAddWallet = false
  @State private var showWalletInfo = false
  @State private var walletToEdit: WalletProfile?
  @State private var walletToDelete: WalletProfile?
  @State private var showConnectionStatus = false
  @State private var showDashboard = false
  @State private var showImportFilePicker = false
  @State private var showImportQRScanner = false
  @State private var showExportQR = false
  @State private var exportQRData: Data?
  @State private var importResult: String?
  @State private var showImportResult = false
  @State private var walletID: UUID?
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.modelContext) private var modelContext
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @AppStorage(Constants.fiatPrimaryKey) private var fiatPrimary = false

  private var bitcoinService: BitcoinService {
    BitcoinService.shared
  }

  private var fiatService: FiatPriceService {
    FiatPriceService.shared
  }

  private var activeWalletName: String {
    wallets.first(where: { $0.isActive })?.name ?? viewModel.walletName
  }

  private var isPrivate: Bool {
    wallets.first(where: { $0.isActive })?.privacyMode ?? false
  }

  private func txLabel(for txid: String) -> String? {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "tx" && $0.ref == txid })?.label
  }

  private func exportLabelsToFile() {
    guard let profile = bitcoinService.currentProfile else { return }
    let walletID = profile.id
    let cosigners = profile.cosigners
    let frozenOutpoints = Set(frozenUTXOs.filter { $0.walletID == walletID }.map(\.outpoint))
    let receiveAddresses = bitcoinService.getAddresses(keychain: .external)
    let changeAddresses = bitcoinService.getAddresses(keychain: .internal)

    let data = LabelService.exportBIP329(
      walletID: walletID,
      context: modelContext,
      transactions: bitcoinService.transactions,
      utxos: bitcoinService.utxos,
      frozenOutpoints: frozenOutpoints,
      receiveAddresses: receiveAddresses,
      changeAddresses: changeAddresses,
      cosigners: cosigners,
      requiredSignatures: profile.requiredSignatures,
      network: profile.bitcoinNetwork
    )

    let sanitizedName = profile.name.replacingOccurrences(of: " ", with: "-")
    let fileName = "\(sanitizedName)-labels.jsonl"
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    try? data.write(to: tempURL)

    let activityVC = UIActivityViewController(
      activityItems: [tempURL],
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

      guard let profile = bitcoinService.currentProfile else { return }

      do {
        let count = try LabelService.importBIP329(
          data: data,
          walletID: profile.id,
          cosigners: profile.cosigners,
          context: modelContext
        )

        if count == 0 {
          importResult = "No new labels found to import."
        } else {
          importResult = "Successfully imported \(count) label\(count == 1 ? "" : "s")."
        }
      } catch {
        logger.error("Failed to save imported labels: \(error.localizedDescription)")
        importResult = "Failed to save imported labels."
      }
      showImportResult = true

    case .failure:
      importResult = "Failed to select a file."
      showImportResult = true
    }
  }

  private func exportLabelsToQR() {
    exportQRData = nil
    showExportQR = true
  }

  private func buildExportData() -> Data {
    guard let profile = bitcoinService.currentProfile else { return Data() }
    let walletID = profile.id
    let frozenOutpoints = Set(frozenUTXOs.filter { $0.walletID == walletID }.map(\.outpoint))
    let receiveAddresses = bitcoinService.getAddresses(keychain: .external)
    let changeAddresses = bitcoinService.getAddresses(keychain: .internal)

    return LabelService.exportBIP329(
      walletID: walletID,
      context: modelContext,
      transactions: bitcoinService.transactions,
      utxos: bitcoinService.utxos,
      frozenOutpoints: frozenOutpoints,
      receiveAddresses: receiveAddresses,
      changeAddresses: changeAddresses,
      cosigners: profile.cosigners,
      requiredSignatures: profile.requiredSignatures,
      network: profile.bitcoinNetwork
    )
  }

  private func handleQRImportResult(_ result: AppURResult) {
    showImportQRScanner = false

    guard case let .rawBytes(data) = result else {
      importResult = "Unexpected QR code type. Expected UR-encoded labels."
      showImportResult = true
      return
    }

    guard let profile = bitcoinService.currentProfile else { return }

    do {
      let count = try LabelService.importBIP329(
        data: data,
        walletID: profile.id,
        cosigners: profile.cosigners,
        context: modelContext
      )

      if count == 0 {
        importResult = "No new labels found to import."
      } else {
        importResult = "Successfully imported \(count) label\(count == 1 ? "" : "s")."
      }
    } catch {
      logger.error("Failed to save imported labels from QR: \(error.localizedDescription)")
      importResult = "Failed to save imported labels."
    }
    showImportResult = true
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Wallet hero header
        VStack(spacing: 12) {
          // Wallet selector + menu row
          HStack {
            Menu {
              Button(action: { showDashboard = true }) {
                Label("Dashboard", systemImage: "chart.bar.xaxis")
              }
              Button(action: { showWalletInfo = true }) {
                Label("Wallet Info", systemImage: "info.circle")
              }
              Menu {
                Button(action: { showImportFilePicker = true }) {
                  Label("Labels File Import", systemImage: "square.and.arrow.down")
                }
                Button(action: { exportLabelsToFile() }) {
                  Label("Labels File Export", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(action: { showImportQRScanner = true }) {
                  Label("Labels QR Import", systemImage: "qrcode.viewfinder")
                }
              } label: {
                Label("Wallet Labels", systemImage: "tag")
              }
            } label: {
              Image(systemName: "ellipsis")
                .font(.system(size: 20))
                .foregroundStyle(Color.hbTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("walletMenu")

            Spacer()

            // Wallet picker
            Button(action: { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker.toggle() } }) {
              HStack(spacing: 8) {
                if let walletID {
                  WalletIdenticon(id: walletID)
                    .frame(width: 24, height: 24)
                }
                Text(activeWalletName)
                  .font(.hbHeadline)
                  .foregroundStyle(Color.hbTextPrimary)
                Image(systemName: showWalletPicker ? "chevron.up" : "chevron.down")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(Color.hbTextSecondary)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .overlay(
                RoundedRectangle(cornerRadius: 22)
                  .strokeBorder(Color.hbBorder, lineWidth: 1)
              )
            }
            .accessibilityIdentifier("walletPicker")

            Spacer()

            // Connection status
            Button(action: { showConnectionStatus = true }) {
              SyncStatusDot(state: viewModel.syncState)
            }
          }

          // Balance
          VStack(spacing: 2) {
            if isPrivate {
              Text(Constants.privacyText())
                .font(.hbAmountLarge)
                .foregroundStyle(Color.hbTextPrimary)
            } else if fiatEnabled, fiatPrimary, let fiatStr = fiatService.formattedSatsToFiat(viewModel.balance) {
              Text(fiatStr)
                .font(.hbAmountLarge)
                .foregroundStyle(Color.hbTextPrimary)
              Text(viewModel.balance.formattedSats)
                .font(.hbBody(14))
                .foregroundStyle(Color.hbTextSecondary)
            } else {
              Text(viewModel.balance.formattedSats)
                .font(.hbAmountLarge)
                .foregroundStyle(Color.hbTextPrimary)
              if fiatEnabled, let fiatStr = fiatService.formattedSatsToFiat(viewModel.balance) {
                Text(fiatStr)
                  .font(.hbBody(14))
                  .foregroundStyle(Color.hbTextSecondary)
              }
            }
          }
          .onLongPressGesture {
            togglePrivacyMode()
          }
          .onTapGesture(count: 2) {
            if fiatEnabled {
              fiatPrimary.toggle()
            }
          }

          // Info row
          HStack {
            NetworkBadge(network: viewModel.network)

            Spacer()

            if let syncMsg = viewModel.syncState.syncMessage {
              Text(syncMsg)
                .font(.hbLabel(11))
                .foregroundStyle(Color.hbTextSecondary)
                .contentTransition(.numericText())
            } else if let lastSynced = viewModel.syncState.lastSynced {
              TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("Last refreshed \(lastSynced.relativeString)")
                  .font(.hbLabel(11))
                  .foregroundStyle(Color.hbTextSecondary)
              }
            }
          }
        }
        .padding(16)
        .background(Color.hbHeroBackground)

        // Transactions section header
        HStack {
          Text("Transactions")
            .font(.hbHeadline)
            .foregroundStyle(Color.hbTextPrimary)
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)

        transactionContent
      }
      .background(Color.hbBackground)
      .navigationTitle("")
      .onDisappear {
        walletPickerEditMode = false
        showWalletPicker = false
      }
      .refreshable {
        await viewModel.refresh()
      }
      .overlay { walletPickerOverlay }
      .sheet(isPresented: $showConnectionStatus) {
        ConnectionStatusView()
      }
      .sheet(isPresented: $showDashboard) {
        WalletDashboardView()
      }
      .sheet(isPresented: $showAddWallet, onDismiss: {
        if let active = wallets.first(where: { $0.isActive }),
           bitcoinService.currentProfile?.id != active.id
        {
          viewModel.clearState()
          bitcoinService.unloadWallet()
          viewModel.loadActiveWallet(from: wallets)
        }
      }) {
        SetupWizardView(canDismiss: true)
          .interactiveDismissDisabled()
      }
      .sheet(isPresented: $showWalletInfo, onDismiss: {
        walletToEdit = nil
      }) {
        if let wallet = walletToEdit ?? wallets.first(where: { $0.isActive }) {
          NavigationStack {
            WalletInfoView(wallet: wallet)
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Done") { showWalletInfo = false }
                    .foregroundStyle(Color.hbBitcoinOrange)
                }
              }
          }
        }
      }
      .fileImporter(
        isPresented: $showImportFilePicker,
        allowedContentTypes: [UTType(filenameExtension: "jsonl") ?? .plainText],
        allowsMultipleSelection: false
      ) { result in
        importLabelsFromFile(result: result)
      }
      .alert("Delete Wallet?", isPresented: .init(
        get: { walletToDelete != nil },
        set: {
          if !$0 {
            walletToDelete = nil
          }
        }
      )) {
        Button("Delete", role: .destructive) {
          if let wallet = walletToDelete {
            walletManager.deleteWallet(wallet, modelContext: modelContext)
          }
          walletToDelete = nil
        }
        Button("Cancel", role: .cancel) { walletToDelete = nil }
      } message: {
        Text("Are you sure you want to delete \"\(walletToDelete?.name ?? "")\"? This cannot be undone. You can re-import using your output descriptor.")
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
      }
      .sheet(isPresented: $showExportQR) {
        NavigationStack {
          ZStack {
            Color.hbBackground.ignoresSafeArea()

            VStack(spacing: 16) {
              if let data = exportQRData {
                URDisplaySheet(data: data, urType: "bytes", maxFragmentLen: 400)
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
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") { showExportQR = false }
            }
          }
        }
        .task {
          if exportQRData == nil {
            let data = buildExportData()
            exportQRData = data
          }
        }
      }
    }
    .id(walletID)
    .onAppear {
      walletID = BitcoinService.shared.currentProfile?.id
      viewModel.loadActiveWallet(from: wallets)
      bitcoinService.startAutoSync()
      bitcoinService.autoSyncIfNeeded()
      viewModel.updateFromService()
      if fiatEnabled {
        Task { await fiatService.fetchRatesIfNeeded() }
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        bitcoinService.startAutoSync()
        bitcoinService.autoSyncIfNeeded()
        viewModel.updateFromService()
        if fiatEnabled {
          Task { await fiatService.fetchRatesIfNeeded() }
        }
      } else {
        walletPickerEditMode = false
        showWalletPicker = false
        bitcoinService.stopAutoSync()
      }
    }
    .onChange(of: bitcoinService.syncState) { _, newState in
      viewModel.updateFromService()
      if case .synced = newState, let walletID = bitcoinService.currentProfile?.id {
        do {
          try LabelService.propagateAddressLabels(
            transactions: bitcoinService.transactions,
            utxos: bitcoinService.utxos,
            context: modelContext,
            walletID: walletID
          )
        } catch {
          logger.error("Failed to propagate address labels after sync: \(error.localizedDescription)")
        }
      }
    }
    .onChange(of: BitcoinService.shared.currentProfile?.id) {
      walletID = BitcoinService.shared.currentProfile?.id
      viewModel.loadActiveWallet(from: wallets)
    }
  }

  private func togglePrivacyMode() {
    guard let wallet = wallets.first(where: { $0.isActive }) else { return }
    wallet.privacyMode.toggle()
    try? modelContext.save()
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.impactOccurred()
  }

  @ViewBuilder
  private var walletPickerOverlay: some View {
    if showWalletPicker {
      Color.black.opacity(0.35)
        .ignoresSafeArea()
        .transition(.opacity)
        .onTapGesture {
          walletPickerEditMode = false
          withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker = false }
        }

      VStack {
        VStack(spacing: 0) {
          // Header
          HStack {
            Button(action: {
              walletPickerEditMode.toggle()
            }) {
              Text(walletPickerEditMode ? "Done" : "Edit")
                .font(.hbBody(15))
                .foregroundStyle(walletPickerEditMode ? Color.hbSuccess : Color.hbTextSecondary)
            }
            Spacer()
            Text("Wallets")
              .font(.hbHeadline)
              .foregroundStyle(Color.hbTextPrimary)
            Spacer()
            Button(action: {
              walletPickerEditMode = false
              withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker = false }
              showAddWallet = true
            }) {
              Text("Add")
                .font(.hbBody(15))
                .foregroundStyle(Color.hbBitcoinOrange)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)

          Divider()
            .background(Color.hbBorder)

          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(wallets.enumerated()), id: \.element.id) { index, wallet in
                HStack(spacing: 12) {
                  if walletPickerEditMode {
                    Image(systemName: "minus.circle.fill")
                      .font(.system(size: 20))
                      .foregroundStyle(Color.hbError)
                      .onTapGesture {
                        walletToDelete = wallet
                      }
                  }

                  WalletIdenticon(id: wallet.id)
                    .frame(width: 32, height: 32)
                    .overlay(
                      RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.hbBitcoinOrange, lineWidth: wallet.isActive ? 2 : 0)
                    )
                  VStack(spacing: 4) {
                    NetworkBadge(network: wallet.bitcoinNetwork)
                    Text(wallet.multisigDescription)
                      .font(.hbLabel())
                      .foregroundStyle(Color.hbTextSecondary)
                  }
                  .fixedSize()
                  Text(wallet.name)
                    .font(.hbBody())
                    .foregroundStyle(Color.hbTextPrimary)
                  Spacer()

                  if walletPickerEditMode {
                    Image(systemName: "chevron.right")
                      .font(.system(size: 14, weight: .semibold))
                      .foregroundStyle(Color.hbTextSecondary)
                  }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 15)
                .background(wallet.isActive ? Color.hbBitcoinOrange.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                  if walletPickerEditMode {
                    walletToEdit = wallet
                    walletPickerEditMode = false
                    withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker = false }
                    showWalletInfo = true
                  } else {
                    guard !wallet.isActive else {
                      withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker = false }
                      return
                    }
                    viewModel.clearState()
                    walletManager.setActiveWallet(wallet, allWallets: wallets, modelContext: modelContext)
                    withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker = false }
                  }
                }
                .onLongPressGesture {
                  walletPickerEditMode = true
                }
                if index < wallets.count - 1 {
                  Divider()
                    .background(Color.hbBorder)
                }
              }
            }
          }
          .scrollBounceBehavior(.basedOnSize)
          .scrollIndicators(.visible)
          .frame(maxHeight: 310)
        }
        .background(Color.hbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.hbBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 35)
        .padding(.top, 60)

        Spacer()
      }
      .transition(.asymmetric(
        insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
        removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)
      ))
    }
  }

  @ViewBuilder
  private var transactionContent: some View {
    if viewModel.transactions.isEmpty, viewModel.isLoading || viewModel.syncState.isSyncing {
      ScrollView {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.top, 150)
      }
    } else if viewModel.transactions.isEmpty {
      ScrollView {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "bitcoinsign.circle",
          description: Text("Time to acquire the world's best money")
        )
        .frame(maxHeight: .infinity)
        .padding(.top, 100)
      }
    } else {
      List(viewModel.transactions) { tx in
        NavigationLink(destination: TransactionDetailView(transaction: tx, network: viewModel.network)) {
          TransactionRowView(transaction: tx, label: txLabel(for: tx.id), showChevron: false, showFiat: fiatEnabled && fiatPrimary, isPrivate: isPrivate)
        }
        .listRowBackground(Color.hbSurface)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
    }
  }
}

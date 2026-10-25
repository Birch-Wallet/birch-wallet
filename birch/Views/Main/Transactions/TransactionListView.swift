import SwiftData
import SwiftUI

private let logger = AppLog(.transactions)

struct TransactionListView: View {
  @Query private var wallets: [WalletProfile]
  @Query private var walletLabels: [WalletLabel]
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

  var body: some View {
    // Amounts format from the Bitcoin unit setting; read it so a change redraws them
    let _ = denomination
    NavigationStack {
      VStack(spacing: 0) {
        // Wallet hero header
        VStack(spacing: 12) {
          // Wallet settings + wallet selector + connection status row
          HStack {
            Button(action: { showWalletInfo = true }) {
              Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18))
                .foregroundStyle(Color.hbTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Wallet Settings")
            .accessibilityIdentifier("walletSettings")

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
              .background(Color.hbTextPrimary.opacity(0.08), in: .rect(cornerRadius: 22, style: .continuous))
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
                .accessibilityIdentifier("balanceFiat")
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
                  .accessibilityIdentifier("balanceFiat")
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
                  .accessibilityIdentifier("lastRefreshed")
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
          // Rarely used, so it stays small: the frame widens the tap area without
          // making the row taller.
          Button(action: { showDashboard = true }) {
            Image(systemName: "chart.bar.xaxis")
              .font(.system(size: 15))
              .foregroundStyle(Color.hbTextPrimary)
              .frame(minWidth: 44, minHeight: 22, alignment: .trailing)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Dashboard")
          .accessibilityIdentifier("dashboardButton")
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
          .birchSheet()
          .birchResizableSheet()
      }
      .sheet(isPresented: $showDashboard) {
        WalletDashboardView()
          .birchSheet()
          .birchResizableSheet()
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
          // Page-sized on iPad so the wizard gets its readable column rather
          // than the phone layout squeezed into a form sheet.
          .presentationSizing(.page)
          .birchSheet()
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
                    .buttonStyle(HBBarButtonStyle(prominent: true))
                }
                .hbHidesGlassBackground()
              }
          }
          .birchSheet()
          .birchResizableSheet()
        }
      }
      .alert("Delete Wallet?", isPresented: .init(
        get: { walletToDelete != nil },
        set: {
          if !$0 {
            walletToDelete = nil
          }
        },
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
            utxos: bitcoinService.outputs,
            context: modelContext,
            walletID: walletID,
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

  /// Closes the wallet picker and opens Wallet Settings for `wallet`, which
  /// needn't be the active one.
  private func openWalletSettings(_ wallet: WalletProfile) {
    walletToEdit = wallet
    walletPickerEditMode = false
    withAnimation(.spring(duration: 0.25, bounce: 0.15)) { showWalletPicker = false }
    showWalletInfo = true
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

          HBDivider()

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

                  Button(action: { openWalletSettings(wallet) }) {
                    Image(systemName: "slider.horizontal.3")
                      .font(.system(size: 17))
                      .foregroundStyle(Color.hbTextSecondary)
                      .frame(width: 40, height: 36, alignment: .trailing)
                      .contentShape(Rectangle())
                  }
                  .accessibilityLabel("Settings for \(wallet.name)")
                  .accessibilityIdentifier("walletPickerSettings")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 15)
                .background(wallet.isActive ? Color.hbBitcoinOrange.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                  if walletPickerEditMode {
                    openWalletSettings(wallet)
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
                  HBDivider()
                }
              }
            }
          }
          .scrollBounceBehavior(.basedOnSize)
          .scrollIndicators(.visible)
          .frame(maxHeight: 310)
        }
        .background(Color.hbFloating)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 60)

        Spacer()
      }
      .transition(.asymmetric(
        insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
        removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity),
      ))
    }
  }

  @ViewBuilder
  private var transactionContent: some View {
    if viewModel.transactions.isEmpty, viewModel.isLoading || viewModel.syncState.isSyncing {
      ScrollView {
        // Centered where the 20pt spinner it replaced was
        SeedlingLoadingView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.top, 100)
      }
    } else if viewModel.transactions.isEmpty {
      ScrollView {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "bitcoinsign.circle",
          description: Text("Time to acquire the world's best money"),
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

import SwiftData
import SwiftUI

struct BroadcastResultView: View {
  @Bindable var viewModel: SendViewModel
  @Binding var selectedTab: Int
  @Environment(\.modelContext) private var modelContext

  @State private var showSuccess = false
  @State private var checkmarkScale: CGFloat = 0
  @State private var ringScale: CGFloat = 0
  @State private var ringOpacity: Double = 1
  @State private var textOpacity: Double = 0
  @State private var txidOpacity: Double = 0
  @State private var countdownSeconds = 5
  @State private var countdownTimer: Timer?

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if showSuccess {
        // Animated success state
        ZStack {
          // Expanding ring
          Circle()
            .strokeBorder(Color.hbSuccess, lineWidth: 3)
            .frame(width: 120, height: 120)
            .scaleEffect(ringScale)
            .opacity(ringOpacity)

          // Checkmark
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 72))
            .foregroundStyle(Color.hbSuccess)
            .scaleEffect(checkmarkScale)
        }

        Text("Transaction Broadcast!")
          .font(.hbDisplay(24))
          .foregroundStyle(Color.hbTextPrimary)
          .opacity(textOpacity)

        VStack(spacing: 8) {
          Text("Transaction ID")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)

          Text(viewModel.broadcastTxid)
            .font(.hbMono(11))
            .foregroundStyle(Color.hbTextPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

          Button(action: {
            UIPasteboard.general.string = viewModel.broadcastTxid
          }) {
            Label("Copy TXID", systemImage: "doc.on.doc")
              .font(.hbBody(14))
              .foregroundStyle(Color.hbSteelBlue)
          }
        }
        .opacity(txidOpacity)
      } else if viewModel.broadcastTxid.isEmpty {
        // Ready to broadcast
        SignatureProgressView(
          collected: viewModel.signaturesCollected,
          required: viewModel.requiredSignatures,
          signerStatus: viewModel.signerStatus
        )

        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 48))
          .foregroundStyle(Color.hbBitcoinOrange)

        Text("Ready to Broadcast")
          .font(.hbDisplay(24))
          .foregroundStyle(Color.hbTextPrimary)

        Text("All required signatures have been collected")
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextSecondary)
      }

      Spacer()

      if showSuccess {
        Button(action: {
          navigateToTransactions()
        }) {
          Text("View Transactions (\(countdownSeconds))")
            .hbPrimaryButton()
        }
        .padding(.horizontal, 24)
        .opacity(txidOpacity)
      } else if viewModel.broadcastTxid.isEmpty {
        Button(action: {
          Task { await viewModel.broadcast() }
        }) {
          if viewModel.isProcessing {
            ProgressView()
              .tint(.white)
              .hbPrimaryButton()
          } else {
            Text("Broadcast Transaction")
              .hbPrimaryButton()
          }
        }
        .disabled(viewModel.isProcessing)
        .padding(.horizontal, 24)

        Button(action: { viewModel.showExportQR = true }) {
          Label("Export Transaction", systemImage: "qrcode")
            .font(.hbBody(15))
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }

      if viewModel.broadcastTxid.isEmpty, !showSuccess {
        Button(action: {
          viewModel.currentStep = .recipients
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            viewModel.reset()
          }
        }) {
          Text("Exit")
            .font(.hbBody(16))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }

      Spacer().frame(height: 32)
    }
    .onAppear {
      viewModel.finalizeTx()
    }
    .onChange(of: viewModel.broadcastTxid) {
      if !viewModel.broadcastTxid.isEmpty {
        saveRecipientLabels()
        viewModel.deleteSavedPSBT(context: modelContext)
        playCelebration()
      }
    }
    .onDisappear {
      countdownTimer?.invalidate()
    }
    .sheet(isPresented: $viewModel.showExportQR) {
      ExportTransactionSheet(txBytes: viewModel.finalizedTxBytes)
    }
  }

  private func playCelebration() {
    // Staggered animation sequence
    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
      showSuccess = true
      checkmarkScale = 1.0
    }

    withAnimation(.easeOut(duration: 0.6)) {
      ringScale = 2.0
    }
    withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
      ringOpacity = 0
    }

    withAnimation(.easeIn(duration: 0.3).delay(0.25)) {
      textOpacity = 1
    }
    withAnimation(.easeIn(duration: 0.3).delay(0.5)) {
      txidOpacity = 1
    }

    // Auto-navigate countdown
    countdownSeconds = 5
    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
      Task { @MainActor in
        countdownSeconds -= 1
        if countdownSeconds <= 0 {
          timer.invalidate()
          navigateToTransactions()
        }
      }
    }
  }

  private func navigateToTransactions() {
    countdownTimer?.invalidate()
    viewModel.reset()
    selectedTab = 0
    // Sync after navigation so the new transaction appears in the list
    Task {
      try? await BitcoinService.shared.sync()
    }
  }

  private func saveRecipientLabels() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    var firstLabel: String?
    for recipient in viewModel.recipients {
      var trimmed = recipient.label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if trimmed.utf8.count > WalletLabel.maxLabelLength {
        trimmed = String(trimmed.utf8.prefix(WalletLabel.maxLabelLength))!
      }
      if firstLabel == nil { firstLabel = trimmed }
      let address = recipient.address.trimmingCharacters(in: .whitespacesAndNewlines)
      // Save as address label — update if one already exists
      let addrType = "addr"
      let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
        $0.walletID == walletID && $0.type == addrType && $0.ref == address
      })
      if let existing = (try? modelContext.fetch(descriptor))?.first {
        existing.label = trimmed
      } else {
        modelContext.insert(WalletLabel(walletID: walletID, type: .addr, ref: address, label: trimmed))
      }
    }
    // Save the first non-empty recipient label as the tx label
    if let txLabel = firstLabel {
      let txid = viewModel.broadcastTxid
      let txType = "tx"
      let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
        $0.walletID == walletID && $0.type == txType && $0.ref == txid
      })
      if let existing = (try? modelContext.fetch(descriptor))?.first {
        existing.label = txLabel
      } else {
        modelContext.insert(WalletLabel(walletID: walletID, type: .tx, ref: txid, label: txLabel))
      }

      // Propagate to change output if there is one
      if let changeAddress = viewModel.changeAddress, !changeAddress.isEmpty,
         let changeVout = BitcoinService.shared.psbtChangeVout(viewModel.psbtBytes, changeAddress: changeAddress)
      {
        do {
          try LabelService.propagateChangeLabel(
            txid: txid,
            txLabel: txLabel,
            changeAddress: changeAddress,
            changeVout: changeVout,
            context: modelContext,
            walletID: walletID
          )
        } catch {
          AppLog(.labels).error("Failed to propagate change label: \(error.localizedDescription)")
        }
      }
    }
    try? modelContext.save()
  }
}

struct ExportTransactionSheet: View {
  let txBytes: Data
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        VStack(spacing: 16) {
          if !txBytes.isEmpty {
            URDisplaySheet(data: txBytes, urType: "bytes")
              .padding(5)
              .background(Color.white)
              .shadow(color: Color.hbBitcoinOrange.opacity(0.2), radius: 20)
          } else {
            Text("Transaction could not be finalized")
              .font(.hbBody())
              .foregroundStyle(Color.hbError)
          }

          Text("Scan to import the signed transaction")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbTextSecondary)
            .multilineTextAlignment(.center)

          Button(action: {
            UIPasteboard.general.string = txBytes.map { String(format: "%02x", $0) }.joined()
          }) {
            Label("Copy Raw TX Hex", systemImage: "doc.on.doc")
              .font(.hbBody(14))
              .foregroundStyle(Color.hbSteelBlue)
          }
        }
        .padding(.top, 8)
      }
      .navigationTitle("Export Transaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
    }
  }
}

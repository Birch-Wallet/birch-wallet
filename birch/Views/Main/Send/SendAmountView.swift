import AVFoundation
import SwiftData
import SwiftUI

struct SendRecipientsView: View {
  @Bindable var viewModel: SendViewModel
  var resumeCandidate: SavedPSBT?
  var onResumeYes: (SavedPSBT) -> Void = { _ in }
  var onResumeNo: () -> Void = {}
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        SendStepIndicator(currentStep: viewModel.currentStep)
          .padding(.horizontal, 24)

        // Resume signing card
        if let saved = resumeCandidate {
          ResumeSigningCard(
            savedPSBT: saved,
            onYes: { onResumeYes(saved) },
            onNo: onResumeNo
          )
          .padding(.horizontal, 24)
        }

        // Spendable balance
        if viewModel.manualUTXOSelection {
          Text("Selected: \(viewModel.selectedUTXOTotal.formattedSats) (\(viewModel.selectedUTXOIds.count) UTXOs)")
            .font(.hbLabel())
            .foregroundStyle(Color.hbBitcoinOrange)
        } else {
          Text("Spendable: \(viewModel.availableBalance.formattedSats)")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
        }

        ForEach(Array(viewModel.recipients.enumerated()), id: \.element.id) { index, _ in
          RecipientCard(viewModel: viewModel, index: index)
        }

        // Fee preset picker
        FeePresetCard(viewModel: viewModel)
          .padding(.horizontal, 24)

        // UTXO selection
        UTXOSelectionCard(viewModel: viewModel)

        if viewModel.showValidationErrors, viewModel.isBalanceExceeded {
          Text("Total amount + estimated fees exceeds spendable balance")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbError)
            .padding(.horizontal, 24)
        }

        // Review button
        Button(action: { viewModel.tryReview() }) {
          if viewModel.isProcessing {
            ProgressView()
              .tint(.white)
              .hbPrimaryButton(isEnabled: viewModel.isReviewReady)
          } else {
            Text("Review")
              .hbPrimaryButton(isEnabled: viewModel.isReviewReady)
          }
        }
        .disabled(viewModel.isProcessing || !viewModel.isReviewReady)
        .padding(.horizontal, 24)

        if viewModel.hasAnyInput {
          Button(action: { viewModel.reset() }) {
            Text("Reset")
              .font(.hbBody(14))
              .foregroundStyle(Color.hbTextSecondary)
          }
        }

        Spacer().frame(height: 32)
      }
      .padding(.top, 16)
    }
    .scrollDismissesKeyboard(.interactively)
    .onTapGesture {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    .sheet(isPresented: $viewModel.showAddressScanner) {
      AddressScannerSheet { scanned in
        let targetIndex = viewModel.scanTargetRecipientIndex
        viewModel.parseBIP21(scanned, forRecipientAt: targetIndex)
        viewModel.showAddressScanner = false
        viewModel.focusAmountIndex = targetIndex
      }
    }
    .sheet(isPresented: $viewModel.showUTXOPicker) {
      UTXOPickerSheet(viewModel: viewModel)
    }
    .task {
      await viewModel.fetchFeeRates()
    }
  }
}

// MARK: - Recipient Card

private struct RecipientCard: View {
  @Bindable var viewModel: SendViewModel
  let index: Int
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @FocusState private var isAmountFocused: Bool

  private var recipient: Recipient? {
    guard index < viewModel.recipients.count else { return nil }
    return viewModel.recipients[index]
  }

  private var addressHasError: Bool {
    guard viewModel.showValidationErrors, let recipient else { return false }
    if recipient.isAddressEmpty {
      return true
    }
    return !recipient.isAddressFormatValid(network: viewModel.currentNetwork)
  }

  /// Show live format error once user has typed something (even before Review tap)
  private var addressFormatError: Bool {
    guard let recipient else { return false }
    return !recipient.isAddressEmpty && !recipient.isAddressFormatValid(network: viewModel.currentNetwork)
  }

  private var amountHasError: Bool {
    guard viewModel.showValidationErrors, let recipient else { return false }
    return !recipient.isSendMax && !recipient.isValidAmount
  }

  var body: some View {
    if index >= viewModel.recipients.count {
      EmptyView()
    } else {
      cardContent
    }
  }

  private var cardContent: some View {
    VStack(spacing: 12) {
      // Header with paste and remove buttons
      HStack(spacing: 0) {
        Text("Recipient \(index + 1)")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        Button(action: {
          if let text = UIPasteboard.general.string {
            viewModel.parseBIP21(text, forRecipientAt: index)
          }
        }) {
          Label("Paste", systemImage: "doc.on.clipboard")
            .font(.hbBody(13))
            .foregroundStyle(Color.hbSteelBlue)
        }
      }
      // Trailing padding to align Paste right edge with address TextField right edge
      // Scan button (44) + HStack spacing (8) = 52
      .padding(.trailing, 52)
      .overlay(alignment: .topTrailing) {
        if viewModel.recipients.count > 1 {
          Button(action: { viewModel.removeRecipient(at: index) }) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(Color.hbTextSecondary)
          }
        }
      }

      // Address + Scan
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          TextField("\(viewModel.currentNetwork?.addressPrefix ?? "bc1")q...", text: $viewModel.recipients[index].address)
            .font(.hbMono(13))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                  (addressHasError || addressFormatError)
                    ? Color.hbError.opacity(0.8) : .clear,
                  lineWidth: 1.5
                )
            )
            .foregroundStyle(Color.hbTextPrimary)

          Button(action: {
            viewModel.scanTargetRecipientIndex = index
            viewModel.showAddressScanner = true
          }) {
            Image(systemName: "qrcode.viewfinder")
              .font(.system(size: 20))
              .foregroundStyle(.white)
              .frame(width: 44, height: 44)
              .background(Color.hbBitcoinOrange)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .contentShape(Rectangle())
          }
        }

        if addressFormatError {
          let expected = viewModel.currentNetwork?.addressPrefix ?? "bc1/tb1"
          Text("Invalid address — expected \(expected)... prefix")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbError)
        } else if viewModel.showValidationErrors, recipient?.isAddressEmpty == true {
          Text("Address is required")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbError)
        }
      }

      // Label
      TextField("Label (optional)", text: $viewModel.recipients[index].label)
        .font(.hbBody(14))
        .padding(12)
        .background(Color.hbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Color.hbTextPrimary)

      // Amount
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          let isMaxActive = viewModel.recipients[index].isSendMax

          if viewModel.amountInFiat {
            HStack(spacing: 4) {
              Text(FiatPriceService.shared.currentCurrencySymbol)
                .font(.hbMono(16))
                .foregroundStyle(Color.hbTextSecondary)

              TextField("0.00", text: fiatBinding(for: index))
                .font(.hbMono(16))
                .keyboardType(.decimalPad)
                .focused($isAmountFocused)
                .disabled(isMaxActive)
                .foregroundStyle(isMaxActive ? Color.hbTextSecondary : Color.hbTextPrimary)
            }
            .padding(12)
            .background(isMaxActive ? Color.hbSurfaceElevated.opacity(0.5) : Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                  amountHasError ? Color.hbError.opacity(0.8) : .clear,
                  lineWidth: 1.5
                )
            )
          } else {
            TextField("0", text: $viewModel.recipients[index].amountSats)
              .font(.hbMono(16))
              .keyboardType(.numberPad)
              .focused($isAmountFocused)
              .disabled(isMaxActive)
              .padding(12)
              .background(isMaxActive ? Color.hbSurfaceElevated.opacity(0.5) : Color.hbSurfaceElevated)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .strokeBorder(
                    amountHasError ? Color.hbError.opacity(0.8) : .clear,
                    lineWidth: 1.5
                  )
              )
              .foregroundStyle(isMaxActive ? Color.hbTextSecondary : Color.hbTextPrimary)
              .onChange(of: viewModel.recipients[index].amountSats) {
                if !isMaxActive {
                  viewModel.recalculateMaxIfNeeded()
                }
              }
          }

          currencyToggle

          // MAX button only on last recipient
          if index == viewModel.recipients.count - 1 {
            Button(action: { viewModel.toggleMaxAmount(for: index) }) {
              Text("MAX")
                .font(.hbLabel(11))
                .foregroundStyle(isMaxActive ? .white : Color.hbBitcoinOrange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isMaxActive ? Color.hbBitcoinOrange : Color.hbBitcoinOrange.opacity(0.15))
                .clipShape(Capsule())
            }
          }
        }

        if amountHasError {
          Text(recipient?.isAmountEmpty == true ? "Amount is required" : "Amount must be greater than 0")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbError)
        } else if viewModel.showValidationErrors, viewModel.recipients[index].isSendMax, (viewModel.recipients[index].amountValue ?? 0) == 0 {
          Text("MAX amount is zero — adjust fees or other recipients")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbError)
        }
      }
    }
    .hbCard()
    .padding(.horizontal, 24)
    .onChange(of: viewModel.focusAmountIndex) {
      if viewModel.focusAmountIndex == index {
        isAmountFocused = true
        viewModel.focusAmountIndex = nil
      }
    }
  }

  @ViewBuilder
  private var currencyToggle: some View {
    if fiatEnabled, viewModel.canToggleFiat {
      Button(action: { viewModel.toggleAmountCurrency() }) {
        VStack(spacing: 1) {
          Image(systemName: "chevron.up")
            .font(.system(size: 8, weight: .bold))
          Text(viewModel.amountInFiat
            ? FiatPriceService.shared.currentCurrencyCode
            : "sats")
            .font(.hbBody(14))
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(Color.hbTextSecondary)
      }
    } else {
      Text("sats")
        .font(.hbBody(14))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  private func fiatBinding(for idx: Int) -> Binding<String> {
    Binding(
      get: {
        guard idx < viewModel.recipients.count else { return "" }
        return viewModel.fiatDisplayAmount[viewModel.recipients[idx].id] ?? ""
      },
      set: { newValue in
        guard idx < viewModel.recipients.count else { return }
        viewModel.fiatDisplayAmount[viewModel.recipients[idx].id] = newValue
        viewModel.updateSatsFromFiat(for: idx)
        viewModel.recalculateMaxIfNeeded()
      }
    )
  }
}

// MARK: - Fee Preset Picker

private struct FeePresetCard: View {
  @Bindable var viewModel: SendViewModel
  @State private var showFeeMenu = false

  private func rateDisplay(_ rate: Double) -> String {
    var s = String(format: "%.2f", rate)
    if s.contains(".") {
      while s.hasSuffix("0") {
        s.removeLast()
      }
      if s.hasSuffix(".") {
        s.removeLast()
      }
    }
    return s
  }

  private var currentRateText: String {
    viewModel.feeRateValue > 0 ? rateDisplay(viewModel.feeRateValue) + " sat/vB" : "--"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header — tap anywhere to expand/collapse
      HStack(spacing: 8) {
        Text("Fee")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        if viewModel.totalSendAmount > 0 {
          Text("~\(viewModel.estimateFee().formattedSats)")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
        }

        Spacer()

        // Current rate in white
        Text(currentRateText)
          .font(.hbMono(14))
          .foregroundStyle(Color.hbTextPrimary)

        // Speed label + directional arrow (left = closed, down = open)
        HStack(spacing: 4) {
          Text(viewModel.selectedFeePreset.displayName)
            .font(.hbBody(14))
            .foregroundStyle(Color.hbBitcoinOrange)
          Image(systemName: showFeeMenu ? "chevron.down" : "chevron.left")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        withAnimation(.easeInOut(duration: 0.2)) { showFeeMenu.toggle() }
      }

      if showFeeMenu {
        Divider()
          .background(Color.hbBorder)

        VStack(spacing: 10) {
          ForEach(FeePreset.allCases, id: \.self) { preset in
            if preset == .custom {
              customRow
            } else {
              presetRow(preset)
            }
          }
        }
      }

      if viewModel.showValidationErrors, !viewModel.isValidFeeRate {
        Text("Enter a fee rate greater than 0")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
      }
    }
    .hbCard()
  }

  private func presetRow(_ preset: FeePreset) -> some View {
    Button(action: {
      viewModel.applyPreset(preset)
      withAnimation(.easeInOut(duration: 0.2)) { showFeeMenu = false }
    }) {
      HStack(spacing: 10) {
        Image(systemName: viewModel.selectedFeePreset == preset ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18))
          .foregroundStyle(viewModel.selectedFeePreset == preset ? Color.hbBitcoinOrange : Color.hbBorder)

        Text(preset.displayName)
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextPrimary)

        Spacer()

        if let rate = preset.rate(from: viewModel.recommendedFees) {
          Text(rateDisplay(rate) + " sat/vB")
            .font(.hbMono(13))
            .foregroundStyle(Color.hbTextPrimary)
        } else {
          Text("-- sat/vB")
            .font(.hbMono(13))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }
      .frame(minHeight: 44)
    }
    .buttonStyle(.plain)
  }

  private var customRow: some View {
    HStack(spacing: 10) {
      Image(systemName: viewModel.selectedFeePreset == .custom ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 18))
        .foregroundStyle(viewModel.selectedFeePreset == .custom ? Color.hbBitcoinOrange : Color.hbBorder)
        .onTapGesture { viewModel.selectedFeePreset = .custom }

      Text(FeePreset.custom.displayName)
        .font(.hbBody(14))
        .foregroundStyle(Color.hbTextPrimary)
        .onTapGesture { viewModel.selectedFeePreset = .custom }

      Spacer()

      TextField("0.0", text: $viewModel.feeRateSatVb)
        .font(.hbMono(14))
        .keyboardType(.decimalPad)
        .multilineTextAlignment(.trailing)
        .frame(width: 60)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.hbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              viewModel.selectedFeePreset == .custom && viewModel.showValidationErrors && !viewModel.isValidFeeRate
                ? Color.hbError.opacity(0.8) : .clear,
              lineWidth: 1.5
            )
        )
        .onChange(of: viewModel.feeRateSatVb) { _, newValue in
          var filtered = newValue.filter { $0.isNumber || $0 == "." }
          if let dotIdx = filtered.firstIndex(of: ".") {
            let afterDot = filtered[filtered.index(after: dotIdx)...]
            filtered = String(filtered[...dotIdx]) + afterDot.filter { $0 != "." }
          }
          if filtered != newValue {
            viewModel.feeRateSatVb = filtered
          }
          // Only switch to .custom when the value wasn't set by applyPreset
          if let rate = viewModel.selectedFeePreset.rate(from: viewModel.recommendedFees),
             viewModel.feeRateSatVb == rateDisplay(rate)
          {
            // Value matches the selected preset — applyPreset wrote this, leave preset as-is
          } else {
            viewModel.selectedFeePreset = .custom
          }
          viewModel.recalculateMaxIfNeeded()
        }
        .onTapGesture { viewModel.selectedFeePreset = .custom }

      Text("sat/vB")
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .frame(minHeight: 44)
  }
}

// MARK: - UTXO Selection

private struct UTXOSelectionCard: View {
  @Bindable var viewModel: SendViewModel

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Coin Selection")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        Toggle("", isOn: Binding(
          get: { viewModel.manualUTXOSelection },
          set: { viewModel.setManualUTXOSelection($0) }
        ))
        .labelsHidden()
        .tint(Color.hbBitcoinOrange)
      }

      if viewModel.manualUTXOSelection {
        Button(action: { viewModel.showUTXOPicker = true }) {
          HStack {
            Image(systemName: "bitcoinsign.circle")
              .font(.system(size: 16))
            Text(viewModel.selectedUTXOIds.isEmpty
              ? "Select UTXOs"
              : "\(viewModel.selectedUTXOIds.count) UTXO\(viewModel.selectedUTXOIds.count == 1 ? "" : "s") selected")
              .font(.hbBody(14))
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 12))
          }
          .foregroundStyle(Color.hbBitcoinOrange)
          .padding(12)
          .background(Color.hbSurfaceElevated)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      } else {
        Text("Automatic — wallet selects optimal UTXOs")
          .font(.hbBody(13))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .hbCard()
    .padding(.horizontal, 24)
  }
}

struct UTXOPickerSheet: View {
  @Bindable var viewModel: SendViewModel
  @Environment(\.dismiss) private var dismiss
  @Query private var walletLabels: [WalletLabel]

  private func utxoLabel(for utxo: UTXOItem) -> String? {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return nil }
    return walletLabels.first(where: { $0.walletID == walletID && $0.type == "utxo" && $0.ref == utxo.id })?.label
  }

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        ScrollView {
          VStack(spacing: 2) {
            ForEach(viewModel.spendableUTXOs) { utxo in
              UTXOPickerRow(
                utxo: utxo,
                isSelected: viewModel.selectedUTXOIds.contains(utxo.id),
                label: utxoLabel(for: utxo),
                onToggle: { viewModel.toggleUTXOSelection(utxo.id) }
              )
            }

            if !viewModel.frozenUTXOs.isEmpty {
              ForEach(viewModel.frozenUTXOs) { utxo in
                FrozenUTXOPickerRow(utxo: utxo, label: utxoLabel(for: utxo))
              }
            }

            if viewModel.allUTXOs.isEmpty {
              Text("No UTXOs available")
                .font(.hbBody())
                .foregroundStyle(Color.hbTextSecondary)
                .padding(.top, 40)
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
        }
      }
      .navigationTitle("Select UTXOs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(Color.hbBitcoinOrange)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button(viewModel.selectedUTXOIds.count == viewModel.spendableUTXOs.count ? "Deselect All" : "Select All") {
            if viewModel.selectedUTXOIds.count == viewModel.spendableUTXOs.count {
              viewModel.selectedUTXOIds.removeAll()
            } else {
              viewModel.selectedUTXOIds = Set(viewModel.spendableUTXOs.map(\.id))
            }
          }
          .foregroundStyle(Color.hbSteelBlue)
          .font(.hbBody(14))
        }
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          Text("\(viewModel.selectedUTXOIds.count) selected")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
          Spacer()
          Text(viewModel.selectedUTXOTotal.formattedSats)
            .font(.hbMonoBold())
            .foregroundStyle(Color.hbBitcoinOrange)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
      }
    }
  }
}

private struct UTXOPickerRow: View {
  let utxo: UTXOItem
  let isSelected: Bool
  let label: String?
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      HStack(spacing: 12) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(isSelected ? Color.hbBitcoinOrange : Color.hbBorder)

        VStack(alignment: .leading, spacing: 4) {
          Text(utxo.amount.formattedSats)
            .font(.hbMono(14))
            .foregroundStyle(Color.hbTextPrimary)

          Text("\(String(utxo.txid.prefix(12)))...:\(utxo.vout)")
            .font(.hbMono(11))
            .foregroundStyle(Color.hbTextSecondary)

          if let label, !label.isEmpty {
            HStack(spacing: 4) {
              Image(systemName: "tag.fill")
                .font(.system(size: 9))
              Text(label)
                .font(.hbBody(11))
                .lineLimit(1)
            }
            .foregroundStyle(Color.hbSteelBlue)
          }
        }

        Spacer()

        HStack(spacing: 4) {
          Circle()
            .fill(utxo.isConfirmed ? Color.hbSuccess : Color.hbBitcoinOrange)
            .frame(width: 6, height: 6)
          Text(utxo.isConfirmed ? "Confirmed" : "Unconfirmed")
            .font(.hbLabel(10))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(isSelected ? Color.hbBitcoinOrange.opacity(0.08) : Color.hbSurface)
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }
}

private struct FrozenUTXOPickerRow: View {
  let utxo: UTXOItem
  let label: String?

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "circle")
        .font(.system(size: 22))
        .foregroundStyle(Color.hbBorder.opacity(0.5))

      VStack(alignment: .leading, spacing: 4) {
        Text(utxo.amount.formattedSats)
          .font(.hbMono(14))
          .foregroundStyle(Color.hbTextPrimary)

        Text("\(String(utxo.txid.prefix(12)))...:\(utxo.vout)")
          .font(.hbMono(11))
          .foregroundStyle(Color.hbTextSecondary)

        if let label, !label.isEmpty {
          HStack(spacing: 4) {
            Image(systemName: "tag.fill")
              .font(.system(size: 9))
            Text(label)
              .font(.hbBody(11))
              .lineLimit(1)
          }
          .foregroundStyle(Color.hbSteelBlue)
        }
      }

      Spacer()

      HStack(spacing: 4) {
        Image(systemName: "snowflake")
          .font(.system(size: 10))
        Text("Frozen")
          .font(.hbLabel(10))
      }
      .foregroundStyle(Color.hbSteelBlue)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.hbSteelBlue.opacity(0.15))
      .clipShape(Capsule())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.hbSurface)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .opacity(0.5)
  }
}

// MARK: - Address QR Scanner (BIP-21 / plain address)

struct AddressScannerSheet: View {
  let onResult: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var scannedCode: String?

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        VStack(spacing: 16) {
          Text("Scan Bitcoin Address")
            .font(.hbDisplay(20))
            .foregroundStyle(Color.hbTextPrimary)

          QRScannerView { code in
            guard scannedCode == nil else { return }
            scannedCode = code
            onResult(code)
          }
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(ScannerOverlay())
          .padding(.horizontal, 24)

          Text("Supports BIP-21 URIs and plain addresses")
            .font(.hbBody(13))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
    }
  }
}

// MARK: - Simple QR Code Scanner (non-UR)

struct QRScannerView: UIViewRepresentable {
  let onCode: (String) -> Void

  func makeUIView(context _: Context) -> QRScannerUIView {
    QRScannerUIView(onCode: onCode)
  }

  func updateUIView(_: QRScannerUIView, context _: Context) {}
}

class QRScannerUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
  private let captureSession = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "qr.scanner.session")
  private let onCode: (String) -> Void
  private var hasReported = false
  private var previewLayer: AVCaptureVideoPreviewLayer?

  init(onCode: @escaping (String) -> Void) {
    self.onCode = onCode
    super.init(frame: .zero)
    setupCamera()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  private func setupCamera() {
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device) else { return }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    let output = AVCaptureMetadataOutput()
    if captureSession.canAddOutput(output) {
      captureSession.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: sessionQueue)
      output.metadataObjectTypes = [.qr]
    }

    let preview = AVCaptureVideoPreviewLayer(session: captureSession)
    preview.videoGravity = .resizeAspectFill
    layer.addSublayer(preview)
    previewLayer = preview
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer?.frame = bounds

    if !captureSession.isRunning {
      sessionQueue.async { [weak self] in
        self?.captureSession.startRunning()
      }
    }
  }

  func metadataOutput(_: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from _: AVCaptureConnection) {
    guard !hasReported,
          let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let code = metadata.stringValue else { return }
    hasReported = true
    sessionQueue.async { [weak self] in
      self?.captureSession.stopRunning()
    }
    DispatchQueue.main.async { [weak self] in
      self?.onCode(code)
    }
  }

  deinit {
    let session = captureSession
    sessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
    }
  }
}

// MARK: - Resume Signing Card

private struct ResumeSigningCard: View {
  let savedPSBT: SavedPSBT
  let onYes: () -> Void
  let onNo: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text("Resume signing last PSBT?")
        .font(.hbBody(15))
        .foregroundStyle(Color.hbTextPrimary)

      Text(savedPSBT.name)
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)

      HStack(spacing: 12) {
        Button(action: onNo) {
          Text("No")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbTextSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        Button(action: onYes) {
          Text("Yes")
            .font(.hbBody(14))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.hbBitcoinOrange)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    .hbCard()
  }
}

// MARK: - Step Indicator

struct SendStepIndicator: View {
  let currentStep: SendViewModel.Step

  private let steps: [(SendViewModel.Step, String)] = [
    (.recipients, "Recipients"),
    (.review, "Review"),
    (.psbtDisplay, "Sign"),
    (.broadcast, "Broadcast"),
  ]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(steps, id: \.0) { step, label in
        VStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2)
            .fill(step.rawValue <= currentStep.rawValue
              ? Color.hbBitcoinOrange
              : Color.hbBorder)
            .frame(height: 3)

          Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(step.rawValue <= currentStep.rawValue
              ? Color.hbBitcoinOrange
              : Color.hbTextSecondary)
        }
      }
    }
  }
}

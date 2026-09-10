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

  @State private var keyboardVisible = false

  /// One recipient keeps the hero amount; more than one switches to numbered
  /// cards that each carry their own amount.
  private var isMultiRecipient: Bool {
    viewModel.recipients.count > 1
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        SendStepIndicator(currentStep: viewModel.currentStep)
          .padding(.bottom, 4)

        if let saved = resumeCandidate {
          ResumeSigningCard(
            savedPSBT: saved,
            onYes: { onResumeYes(saved) },
            onNo: onResumeNo
          )
        }

        if isMultiRecipient {
          spendableHeader
        }

        ForEach(Array(viewModel.recipients.enumerated()), id: \.element.id) { index, _ in
          RecipientCard(viewModel: viewModel, index: index, showsAmount: isMultiRecipient)
        }

        // Address first, then the amount it is being sent to. Multi-recipient
        // mode has no hero — each card carries its own amount.
        if !isMultiRecipient {
          AmountHeroCard(viewModel: viewModel)
        }

        DecisionStack(viewModel: viewModel)

        if viewModel.showValidationErrors, viewModel.isBalanceExceeded {
          Text("Total amount + estimated fees exceeds spendable balance")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbError)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        SendFooter(viewModel: viewModel)

        if viewModel.hasAnyInput {
          Button(action: { viewModel.reset() }) {
            Text("Reset")
              .font(.hbBody(14))
              .foregroundStyle(Color.hbTextSecondary)
          }
          .padding(.top, 4)
        }

        Spacer().frame(height: 8)
      }
      .padding(.horizontal, 24)
      .padding(.top, 12)
    }
    .scrollDismissesKeyboard(.interactively)
    .overlay(alignment: .bottomTrailing) {
      if keyboardVisible, !viewModel.showFeeSheet {
        KeyboardDismissButton()
          .padding(.trailing, 20)
          .padding(.bottom, 12)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: keyboardVisible)
    .onReceive(NotificationCenter.default.publisher(
      for: UIResponder.keyboardWillShowNotification
    )) { _ in
      keyboardVisible = true
    }
    .onReceive(NotificationCenter.default.publisher(
      for: UIResponder.keyboardWillHideNotification
    )) { _ in
      keyboardVisible = false
    }
    .onTapGesture { dismissKeyboard() }
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
    .sheet(isPresented: $viewModel.showFeeSheet) {
      SendFeeSheetView(viewModel: viewModel)
    }
    .task {
      await viewModel.fetchFeeRates()
    }
  }

  /// In multi-recipient mode the spendable line and unit toggle move out of the
  /// hero card and sit above the stack of recipients.
  private var spendableHeader: some View {
    HStack {
      HStack(spacing: 6) {
        Text("Spendable")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        Text(viewModel.selectedUTXOTotal.formattedSats)
          .font(.hbMono(13))
          .foregroundStyle(Color.hbTextPrimary)
      }

      Spacer()

      CurrencyTogglePill(viewModel: viewModel)
    }
  }
}

private func dismissKeyboard() {
  UIApplication.shared.sendAction(
    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
  )
}

// MARK: - Keyboard Dismiss Button

/// A floating control rather than a `.keyboard` toolbar item: that placement
/// installs a window-level accessory view, so it also appeared over the fee
/// sheet's keypad and reserved height there, lifting the sheet off the
/// keyboard. An overlay stays scoped to this screen.
private struct KeyboardDismissButton: View {
  var body: some View {
    Button(action: dismissKeyboard) {
      Image(systemName: "keyboard.chevron.compact.down")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Color.hbBitcoinOrange)
        .frame(width: 44, height: 44)
        .background(
          Circle()
            .fill(Color.hbSurface)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Dismiss keyboard")
  }
}

// MARK: - Currency Toggle Pill

/// Switches the amount between sats and fiat. Falls back to a static "sats"
/// pill when fiat is off or no rate has loaded.
private struct CurrencyTogglePill: View {
  @Bindable var viewModel: SendViewModel
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  private var unitLabel: String {
    viewModel.amountInFiat ? FiatPriceService.shared.currentCurrencyCode : "sats"
  }

  var body: some View {
    if fiatEnabled, viewModel.canToggleFiat {
      Button(action: { viewModel.toggleAmountCurrency() }) {
        HStack(spacing: 4) {
          Text(unitLabel)
            .font(.hbBody(12).weight(.semibold))
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(Color.hbTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.hbSurfaceElevated)
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
    } else {
      Text(unitLabel)
        .font(.hbBody(12).weight(.semibold))
        .foregroundStyle(Color.hbTextSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.hbSurfaceElevated)
        .clipShape(Capsule())
    }
  }
}

// MARK: - Amount Conversion Line

/// The BTC and fiat equivalents under an amount. Shared so a recipient card
/// reads the same whether it is the single-recipient hero or one of several
/// numbered cards.
private struct AmountConversionLine: View {
  let sats: UInt64
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  var body: some View {
    if sats > 0 {
      HStack(spacing: 10) {
        Text("\(sats.formattedBTC) BTC")
          .font(.hbMono(13))
          .foregroundStyle(Color.hbTextSecondary)

        if fiatEnabled, let fiat = FiatPriceService.shared.formattedSatsToFiat(sats) {
          Circle()
            .fill(Color.hbBorder)
            .frame(width: 3, height: 3)

          Text("≈ \(fiat)")
            .font(.hbMono(13))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - MAX Pill

private struct MaxPill: View {
  @Bindable var viewModel: SendViewModel
  let index: Int

  private var isActive: Bool {
    index < viewModel.recipients.count && viewModel.recipients[index].isSendMax
  }

  var body: some View {
    Button(action: { viewModel.toggleMaxAmount(for: index) }) {
      Text("MAX")
        .font(.hbMonoBold(12))
        .foregroundStyle(isActive ? .white : Color.hbBitcoinOrange)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isActive ? Color.hbBitcoinOrange : Color.hbBitcoinOrange.opacity(0.15))
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Amount Hero

/// The amount is the figure the user is actually deciding, so it gets the
/// largest type on the screen. Spendable sits inside the same card, next to
/// the number it constrains.
private struct AmountHeroCard: View {
  @Bindable var viewModel: SendViewModel
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @FocusState private var isAmountFocused: Bool

  private let index = 0

  private var recipient: Recipient? {
    viewModel.recipients.first
  }

  private var isMaxActive: Bool {
    recipient?.isSendMax ?? false
  }

  private var amountText: String {
    viewModel.amountInFiat
      ? (viewModel.fiatDisplayAmount[recipient?.id ?? UUID()] ?? "")
      : (recipient?.amountSats ?? "")
  }

  /// Sized to hold eight digits; longer values step down rather than wrap.
  private var amountFontSize: CGFloat {
    switch amountText.count {
    case ...8: 40
    case 9 ... 11: 32
    default: 26
    }
  }

  private var hasError: Bool {
    guard viewModel.showValidationErrors, let recipient else { return false }
    return !recipient.isSendMax && !recipient.isValidAmount
  }

  var body: some View {
    VStack(spacing: 14) {
      HStack {
        Text("Amount")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        HStack(spacing: 8) {
          MaxPill(viewModel: viewModel, index: index)
          CurrencyTogglePill(viewModel: viewModel)
        }
      }

      amountField

      if let sats = recipient?.amountValue {
        AmountConversionLine(sats: sats)
      }

      if hasError {
        Text(recipient?.isAmountEmpty == true ? "Amount is required" : "Amount must be greater than 0")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if viewModel.showValidationErrors, isMaxActive, (recipient?.amountValue ?? 0) == 0 {
        Text("MAX amount is zero — adjust fees or other recipients")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider().overlay(Color.hbBorder)

      HStack {
        Text(viewModel.manualUTXOSelection ? "Selected" : "Spendable")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        Text(viewModel.selectedUTXOTotal.formattedSats)
          .font(.hbMono(13))
          .foregroundStyle(Color.hbTextPrimary)
      }
    }
    .padding(20)
    .background(Color.hbSurface)
    .clipShape(RoundedRectangle(cornerRadius: 22))
    .overlay(
      RoundedRectangle(cornerRadius: 22)
        .strokeBorder(hasError ? Color.hbError.opacity(0.8) : Color.hbBorder, lineWidth: hasError ? 1.5 : 0.5)
    )
    .onChange(of: viewModel.focusAmountIndex) {
      if viewModel.focusAmountIndex == index {
        isAmountFocused = true
        viewModel.focusAmountIndex = nil
      }
    }
  }

  private var amountField: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      if viewModel.amountInFiat {
        Text(FiatPriceService.shared.currentCurrencySymbol)
          .font(.system(size: amountFontSize, weight: .regular, design: .monospaced))
          .foregroundStyle(Color.hbTextSecondary)

        TextField("0.00", text: fiatBinding)
          .font(.system(size: amountFontSize, weight: .regular, design: .monospaced))
          .keyboardType(.decimalPad)
          .focused($isAmountFocused)
          .disabled(isMaxActive)
          .foregroundStyle(isMaxActive ? Color.hbTextSecondary : Color.hbTextPrimary)
      } else {
        TextField("0", text: $viewModel.recipients[index].amountSats)
          .font(.system(size: amountFontSize, weight: .regular, design: .monospaced))
          .keyboardType(.numberPad)
          .focused($isAmountFocused)
          .disabled(isMaxActive)
          .foregroundStyle(isMaxActive ? Color.hbTextSecondary : Color.hbTextPrimary)
          .onChange(of: viewModel.recipients[index].amountSats) {
            if !isMaxActive {
              viewModel.recalculateMaxIfNeeded()
            }
          }

        Text("sats")
          .font(.hbMono(18))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var fiatBinding: Binding<String> {
    Binding(
      get: {
        guard let id = viewModel.recipients.first?.id else { return "" }
        return viewModel.fiatDisplayAmount[id] ?? ""
      },
      set: { newValue in
        guard let id = viewModel.recipients.first?.id else { return }
        viewModel.fiatDisplayAmount[id] = newValue
        viewModel.updateSatsFromFiat(for: index)
        viewModel.recalculateMaxIfNeeded()
      }
    )
  }
}

// MARK: - Recipient Card

/// Scanning and pasting are how addresses actually get entered, so they are the
/// visible controls; the raw text field is revealed only when asked for. Once
/// an address exists the card switches to a verifiable summary — head and tail
/// in monospace plus the network it belongs to.
private struct RecipientCard: View {
  @Bindable var viewModel: SendViewModel
  let index: Int
  /// Multi-recipient mode gives each card its own amount row.
  var showsAmount: Bool = false

  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @FocusState private var isAmountFocused: Bool
  @FocusState private var isAddressFocused: Bool
  @FocusState private var isLabelFocused: Bool
  @State private var showAddressField = false
  @State private var isEditingLabel = false
  @State private var showFullAddress = false

  private var recipient: Recipient? {
    guard index < viewModel.recipients.count else { return nil }
    return viewModel.recipients[index]
  }

  private var hasAddress: Bool {
    !(recipient?.isAddressEmpty ?? true)
  }

  private var addressFormatError: Bool {
    guard let recipient else { return false }
    return !recipient.isAddressEmpty && !recipient.isAddressFormatValid(network: viewModel.currentNetwork)
  }

  private var addressMissing: Bool {
    viewModel.showValidationErrors && (recipient?.isAddressEmpty ?? false)
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
    VStack(alignment: .leading, spacing: 12) {
      header

      if hasAddress, !showAddressField {
        filledAddress
      } else {
        addressEntry
      }

      if addressFormatError {
        let expected = viewModel.currentNetwork?.addressPrefix ?? "bc1/tb1"
        Text("Invalid address — expected \(expected)... prefix")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
      } else if addressMissing {
        Text("Address is required")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
      }

      if showsAmount {
        Divider().overlay(Color.hbBorder)
        amountRow
      }
    }
    .padding(16)
    .background(Color.hbSurface)
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .overlay(
      RoundedRectangle(cornerRadius: 20)
        .strokeBorder(
          (addressFormatError || addressMissing) ? Color.hbError.opacity(0.8) : Color.hbBorder,
          lineWidth: (addressFormatError || addressMissing) ? 1.5 : 0.5
        )
    )
    .onAppear { focusAmountIfRequested() }
    .onChange(of: viewModel.focusAmountIndex) { focusAmountIfRequested() }
  }

  /// Only the card that actually draws an amount field may claim the request —
  /// in single-recipient mode that field lives in the hero card instead.
  private func focusAmountIfRequested() {
    guard showsAmount, viewModel.focusAmountIndex == index else { return }
    // A newly inserted card isn't in the responder chain yet on this pass.
    DispatchQueue.main.async {
      isAmountFocused = true
      viewModel.focusAmountIndex = nil
    }
  }

  // MARK: Header — the label lives here, so every recipient carries its own

  private var header: some View {
    HStack(alignment: .center, spacing: 9) {
      if showsAmount {
        Text("\(index + 1)")
          .font(.hbMonoBold(11))
          .foregroundStyle(Color.hbBitcoinOrange)
          .frame(width: 20, height: 20)
          .background(Color.hbBitcoinOrange.opacity(0.15))
          .clipShape(Circle())
      }

      if hasAddress {
        // Filled: the label is the card's title, the network sits opposite it
        labelControl

        Spacer(minLength: 8)

        if let network = viewModel.currentNetwork {
          Text(network.displayName)
            .font(.hbBody(11).weight(.semibold))
            .foregroundStyle(Color.hbSteelBlue)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.hbSteelBlue.opacity(0.15))
            .clipShape(Capsule())
        }
      } else {
        // Empty: "Send to" names the card, the label link is the optional extra
        Text("Send to")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer(minLength: 8)

        labelControl
      }

      if viewModel.recipients.count > 1 {
        Button(action: { viewModel.removeRecipient(at: index) }) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.hbTextSecondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private var labelControl: some View {
    let labelText = viewModel.recipients[index].label.trimmingCharacters(in: .whitespacesAndNewlines)

    if isEditingLabel {
      TextField("Label", text: $viewModel.recipients[index].label)
        .font(.hbBody(14))
        .focused($isLabelFocused)
        .foregroundStyle(Color.hbTextPrimary)
        .onSubmit { isEditingLabel = false }
        .onChange(of: isLabelFocused) {
          if !isLabelFocused {
            isEditingLabel = false
          }
        }
        .frame(maxWidth: 200)
    } else {
      Button(action: {
        isEditingLabel = true
        isLabelFocused = true
      }) {
        VStack(alignment: .leading, spacing: 4) {
          if !labelText.isEmpty, !showsAmount {
            Text("Label · optional")
              .font(.hbLabel(11))
              .foregroundStyle(Color.hbTextSecondary)
          }
          Text(labelText.isEmpty ? "Add label" : labelText)
            .font(labelText.isEmpty ? .hbBody(13) : .hbBody(showsAmount ? 13 : 16).weight(.semibold))
            .foregroundStyle(labelText.isEmpty ? Color.hbTextSecondary : Color.hbTextPrimary)
            .lineLimit(1)
            .overlay(alignment: .bottom) {
              Rectangle()
                .fill(Color.hbBorder)
                .frame(height: 1)
                .offset(y: 4)
            }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: Address — empty state

  private var addressEntry: some View {
    VStack(spacing: 12) {
      HStack(spacing: 10) {
        Button(action: {
          viewModel.scanTargetRecipientIndex = index
          viewModel.showAddressScanner = true
        }) {
          HStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
              .font(.system(size: 18, weight: .semibold))
            Text("Scan QR")
              .font(.hbBody(16).weight(.bold))
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 56)
          .background(Color.hbBitcoinOrange)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Button(action: pasteAddress) {
          Text("Paste")
            .font(.hbBody(16).weight(.bold))
            .foregroundStyle(Color.hbSteelBlue)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
              RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.hbBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .frame(maxWidth: .infinity)
      .layoutPriority(1)

      if showAddressField {
        TextField("\(viewModel.currentNetwork?.addressPrefix ?? "bc1")q...", text: $viewModel.recipients[index].address)
          .font(.hbMono(13))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($isAddressFocused)
          .submitLabel(.done)
          .onSubmit { endAddressEditing() }
          .onChange(of: isAddressFocused) {
            // Once the field gives up focus, show the verifiable summary
            if !isAddressFocused {
              endAddressEditing()
            }
          }
          .padding(12)
          .background(Color.hbSurfaceElevated)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .foregroundStyle(Color.hbTextPrimary)
      } else {
        Button(action: {
          showAddressField = true
          isAddressFocused = true
        }) {
          Text("or type an address")
            .font(.hbBody(13))
            .foregroundStyle(Color.hbTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// Leave the raw field only when there is something to summarise; an empty
  /// address falls back to the Scan / Paste buttons.
  private func endAddressEditing() {
    guard hasAddress else { return }
    showAddressField = false
  }

  private func pasteAddress() {
    guard let text = UIPasteboard.general.string else { return }
    viewModel.parseBIP21(text, forRecipientAt: index)
    viewModel.focusAmountIndex = index
  }

  // MARK: Address — filled state

  private var filledAddress: some View {
    HStack(alignment: .center, spacing: 12) {
      Button(action: { showFullAddress.toggle() }) {
        VStack(alignment: .leading, spacing: 5) {
          if showFullAddress {
            viewModel.recipients[index].address.chunkedAddressText(font: .hbMono(13))
              .multilineTextAlignment(.leading)
          } else {
            Text(elidedAddress)
              .font(.hbMono(showsAmount ? 15 : 17))
              .foregroundStyle(Color.hbTextPrimary)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }

          Text(showFullAddress ? "Tap to collapse" : "Tap to show full address")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      HStack(spacing: 8) {
        Button(action: clearAddress) {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.hbTextSecondary)
            .frame(width: 40, height: 40)
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Button(action: {
          viewModel.scanTargetRecipientIndex = index
          viewModel.showAddressScanner = true
        }) {
          Image(systemName: "qrcode.viewfinder")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.hbBitcoinOrange)
            .frame(width: 40, height: 40)
            .background(Color.hbBitcoinOrange.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// Head and tail are what a user can actually check against the hardware
  /// wallet before signing; the middle carries no verification value.
  private var elidedAddress: String {
    let address = viewModel.recipients[index].address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address.count > 20 else { return address }
    return "\(address.prefix(8)) … \(address.suffix(8))"
  }

  private func clearAddress() {
    viewModel.recipients[index].address = ""
    showFullAddress = false
    showAddressField = false
  }

  // MARK: Amount — multi-recipient only

  private var amountRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .bottom, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if viewModel.amountInFiat {
            Text(FiatPriceService.shared.currentCurrencySymbol)
              .font(.hbMono(16))
              .foregroundStyle(Color.hbTextSecondary)

            TextField("0.00", text: fiatBinding)
              .font(.system(size: 28, weight: .regular, design: .monospaced))
              .keyboardType(.decimalPad)
              .focused($isAmountFocused)
              .disabled(viewModel.recipients[index].isSendMax)
              .foregroundStyle(amountColor)
          } else {
            TextField("0", text: $viewModel.recipients[index].amountSats)
              .font(.system(size: 28, weight: .regular, design: .monospaced))
              .keyboardType(.numberPad)
              .focused($isAmountFocused)
              .disabled(viewModel.recipients[index].isSendMax)
              .foregroundStyle(amountColor)
              .onChange(of: viewModel.recipients[index].amountSats) {
                if !viewModel.recipients[index].isSendMax {
                  viewModel.recalculateMaxIfNeeded()
                }
              }

            Text("sats")
              .font(.hbMono(14))
              .foregroundStyle(Color.hbTextSecondary)
          }
        }

        Spacer(minLength: 8)

        // MAX only makes sense on the last recipient — it absorbs the remainder
        if index == viewModel.recipients.count - 1 {
          MaxPill(viewModel: viewModel, index: index)
        }
      }

      if let sats = recipient?.amountValue {
        AmountConversionLine(sats: sats)
      }

      if amountHasError {
        Text(recipient?.isAmountEmpty == true ? "Amount is required" : "Amount must be greater than 0")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
      } else if viewModel.showValidationErrors, viewModel.recipients[index].isSendMax,
                (viewModel.recipients[index].amountValue ?? 0) == 0
      {
        Text("MAX amount is zero — adjust fees or other recipients")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
      }
    }
  }

  private var amountColor: Color {
    viewModel.recipients[index].isSendMax ? Color.hbTextSecondary : Color.hbTextPrimary
  }

  private var fiatBinding: Binding<String> {
    Binding(
      get: {
        guard index < viewModel.recipients.count else { return "" }
        return viewModel.fiatDisplayAmount[viewModel.recipients[index].id] ?? ""
      },
      set: { newValue in
        guard index < viewModel.recipients.count else { return }
        viewModel.fiatDisplayAmount[viewModel.recipients[index].id] = newValue
        viewModel.updateSatsFromFiat(for: index)
        viewModel.recalculateMaxIfNeeded()
      }
    )
  }
}

// MARK: - Decision Stack

/// Fee and coin selection are the same kind of decision — a current state you
/// can drill into — so they read as two rows of one card rather than an
/// accordion and a toggle.
private struct DecisionStack: View {
  @Bindable var viewModel: SendViewModel

  private var feeSubtitle: String {
    guard viewModel.feeRateValue > 0 else { return "Tap to choose a rate" }
    let rate = "\(formatFeeRate(viewModel.feeRateValue)) sat/vB"
    guard viewModel.totalSendAmount > 0 else { return rate }
    return "\(rate) · \(viewModel.estimateFee().formattedSats)"
  }

  private var coinsSubtitle: String {
    guard viewModel.manualUTXOSelection else { return "Automatic — optimal UTXOs" }
    let count = viewModel.selectedUTXOIds.count
    let total = viewModel.spendableUTXOs.count
    return "Manual · \(count) of \(total) · \(viewModel.selectedUTXOTotal.formattedSats)"
  }

  var body: some View {
    VStack(spacing: 0) {
      row(
        title: "Fee",
        subtitle: feeSubtitle,
        subtitleColor: viewModel.feeRateValue > 0 ? Color.hbTextSecondary : Color.hbBitcoinOrange,
        badge: viewModel.selectedFeePreset == .custom ? nil : viewModel.selectedFeePreset.displayName,
        action: { viewModel.showFeeSheet = true }
      )

      Divider().overlay(Color.hbBorder)

      row(
        title: "Coins",
        subtitle: coinsSubtitle,
        subtitleColor: viewModel.manualUTXOSelection ? Color.hbBitcoinOrange : Color.hbTextSecondary,
        badge: nil,
        action: { viewModel.showUTXOPicker = true }
      )

      if viewModel.showValidationErrors, !viewModel.isValidFeeRate {
        Text("Enter a fee rate greater than 0")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 18)
          .padding(.bottom, 12)
      }
    }
    .background(Color.hbSurface)
    .clipShape(RoundedRectangle(cornerRadius: 20))
    .overlay(
      RoundedRectangle(cornerRadius: 20)
        .strokeBorder(Color.hbBorder, lineWidth: 0.5)
    )
  }

  private func row(
    title: String,
    subtitle: String,
    subtitleColor: Color,
    badge: String?,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.hbBody(15).weight(.semibold))
            .foregroundStyle(Color.hbTextPrimary)

          Text(subtitle)
            .font(.hbMono(12))
            .foregroundStyle(subtitleColor)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }

        Spacer(minLength: 8)

        if let badge {
          Text(badge)
            .font(.hbBody(13).weight(.semibold))
            .foregroundStyle(Color.hbBitcoinOrange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.hbBitcoinOrange.opacity(0.15))
            .clipShape(Capsule())
        }

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(minHeight: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Footer

/// The CTA carries the fee-inclusive total above it and names what comes next,
/// so the air-gapped signing flow is never a surprise. Disabled it says why.
private struct SendFooter: View {
  @Bindable var viewModel: SendViewModel

  private var isReady: Bool {
    viewModel.isReviewReady
  }

  private var totalLabel: String {
    viewModel.recipients.count > 1
      ? "\(viewModel.recipients.count) recipients + fee"
      : "Total with fee"
  }

  private var reason: String {
    if isReady {
      return "Next: Review Transaction"
    }
    let missingAddress = viewModel.recipients.contains { $0.isAddressEmpty }
    let missingAmount = viewModel.recipients.contains { !$0.isSendMax && $0.isAmountEmpty }
    switch (missingAddress, missingAmount) {
    case (true, true): return "Enter an address and amount to continue"
    case (true, false): return "Enter an address to continue"
    case (false, true): return "Enter an amount to continue"
    case (false, false): return "Next: Review Transaction"
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      if viewModel.totalSendAmount > 0 {
        HStack {
          Text(totalLabel)
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)

          Spacer()

          Text(viewModel.totalWithEstimatedFee.formattedSats)
            .font(.hbMonoBold(15))
            .foregroundStyle(Color.hbTextPrimary)
        }
        .padding(.horizontal, 4)
      }

      Button(action: { viewModel.tryReview() }) {
        if viewModel.isProcessing {
          ProgressView()
            .tint(.white)
            .hbPrimaryButton(isEnabled: isReady)
        } else {
          Text("Review")
            .hbPrimaryButton(isEnabled: isReady)
        }
      }
      .disabled(viewModel.isProcessing || !isReady)

      Text(reason)
        .font(.hbLabel(12))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .padding(.top, 4)
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
          Button(viewModel.selectedUTXOIds.isEmpty ? "Select All" : "Deselect All") {
            if viewModel.selectedUTXOIds.isEmpty {
              viewModel.selectedUTXOIds = Set(viewModel.spendableUTXOs.map(\.id))
            } else {
              viewModel.useAutomaticCoinSelection()
            }
          }
          .foregroundStyle(Color.hbSteelBlue)
          .font(.hbBody(14))
        }
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          Text(viewModel.selectedUTXOIds.isEmpty
            ? "None selected — the wallet chooses"
            : "\(viewModel.selectedUTXOIds.count) selected")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
          Spacer()
          if !viewModel.selectedUTXOIds.isEmpty {
            Text(viewModel.selectedUTXOTotal.formattedSats)
              .font(.hbMonoBold())
              .foregroundStyle(Color.hbBitcoinOrange)
          }
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

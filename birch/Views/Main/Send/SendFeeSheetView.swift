import SwiftUI

/// Fee selection presented as a sheet rather than an inline accordion, so the
/// send screen stays intact behind it and the Review button never gets pushed
/// off screen. Each preset is priced in sats — a bare sat/vB rate doesn't tell
/// the user what they'll pay, and two presets often resolve to the same rate.
struct SendFeeSheetView: View {
  @Bindable var viewModel: SendViewModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  /// Preset selected while the sheet is open; only committed on "Use …"
  @State private var draftPreset: FeePreset
  @State private var draftRate: String
  /// Latches the typing layout. Kept separate from the focus binding: the
  /// layout swap removes whichever field was focused, so driving it from
  /// @FocusState alone would immediately undo itself.
  @State private var isTypingRate = false
  @FocusState private var isRateFocused: Bool
  @State private var detent: PresentationDetent = .large
  /// Measured rather than guessed — the collapsed detent has to track whatever
  /// the rows actually come out to, and a hand-tuned constant goes stale every
  /// time a row gains or loses a line.
  @State private var contentHeight: CGFloat = 420

  init(viewModel: SendViewModel) {
    self.viewModel = viewModel
    _draftPreset = State(initialValue: viewModel.selectedFeePreset)
    _draftRate = State(initialValue: viewModel.feeRateSatVb)
  }

  private var fiatService: FiatPriceService {
    FiatPriceService.shared
  }

  private var draftRateValue: Double {
    Double(draftRate) ?? 0
  }

  private var draftFee: UInt64 {
    viewModel.estimatedFee(for: draftRateValue)
  }

  private var isValidDraft: Bool {
    draftRateValue > 0
  }

  /// One row per distinct rate. When the fee source returns the same rate for
  /// two presets they share a row — but both names stay on it, so a preset
  /// never looks like it went missing.
  private struct FeeOption: Identifiable {
    let presets: [FeePreset]
    let rate: Double

    var id: Double {
      rate
    }

    var title: String {
      presets.map(\.displayName).joined(separator: " · ")
    }

    var primary: FeePreset {
      presets[0]
    }
  }

  private var feeOptions: [FeeOption] {
    var order: [Double] = []
    var grouped: [Double: [FeePreset]] = [:]
    for preset in [FeePreset.fast, .medium, .slow] {
      guard let rate = preset.rate(from: viewModel.recommendedFees) else { continue }
      let key = (rate * 100).rounded() / 100
      if grouped[key] == nil {
        order.append(key)
        grouped[key] = []
      }
      grouped[key]?.append(preset)
    }
    return order.compactMap { key in
      guard let presets = grouped[key] else { return nil }
      return FeeOption(presets: presets, rate: key)
    }
  }

  var body: some View {
    VStack(spacing: 16) {
      header

      if isTypingRate {
        // Typing a rate: the priced rows would be pushed under the keyboard,
        // so the presets shrink to a reference strip and the rate itself
        // becomes the big figure.
        compactPresetStrip
        focusedCustomField
      } else {
        VStack(spacing: 10) {
          ForEach(feeOptions) { option in
            presetRow(option)
          }
          customRow
        }
      }

      totalRow

      Button(action: commit) {
        Text(commitTitle)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .hbPrimaryButton(isEnabled: isValidDraft)
      }
      .disabled(!isValidDraft)
    }
    .padding(.horizontal, 24)
    .padding(.top, 8)
    .padding(.bottom, 24)
    // Measured before the expanding frame, so this is the intrinsic content
    // height rather than the sheet's.
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      contentHeight = height
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.hbBackground)
    .animation(.easeInOut(duration: 0.2), value: isTypingRate)
    .onAppear { detent = .height(sheetHeight) }
    .onChange(of: sheetHeight) {
      detent = .height(sheetHeight)
    }
    .presentationDetents([.height(sheetHeight)], selection: $detent)
    .presentationDragIndicator(.visible)
    .presentationBackground(Color.hbBackground)
  }

  // MARK: - Typing a custom rate

  /// Presets stay visible as a reference strip — the point of typing a custom
  /// rate is usually to sit somewhere relative to them.
  private var compactPresetStrip: some View {
    HStack(spacing: 8) {
      ForEach(feeOptions) { option in
        Button(action: {
          draftPreset = option.primary
          draftRate = formatFeeRate(option.rate)
          stopTyping()
        }) {
          VStack(spacing: 4) {
            Text(option.title)
              .font(.hbBody(13).weight(.bold))
              .foregroundStyle(Color.hbTextPrimary)
            Text(formatFeeRate(option.rate))
              .font(.hbMono(11))
              .foregroundStyle(Color.hbTextSecondary)
          }
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .padding(.horizontal, 8)
          .background(
            RoundedRectangle(cornerRadius: 14)
              .fill(Color.hbSurface)
              .overlay(
                RoundedRectangle(cornerRadius: 14)
                  .strokeBorder(Color.hbBorder, lineWidth: 0.5)
              )
          )
        }
        .buttonStyle(.plain)
      }

      VStack(spacing: 4) {
        Text(FeePreset.custom.displayName)
          .font(.hbBody(13).weight(.bold))
        Text(isValidDraft ? formatFeeRate(draftRateValue) : "—")
          .font(.hbMono(11))
      }
      .foregroundStyle(Color.hbBitcoinOrange)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(Color.hbBitcoinOrange.opacity(0.12))
          .overlay(
            RoundedRectangle(cornerRadius: 14)
              .strokeBorder(Color.hbBitcoinOrange, lineWidth: 1.5)
          )
      )
    }
  }

  private var focusedCustomField: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Custom fee rate")
          .font(.hbLabel())
          .foregroundStyle(Color.hbBitcoinOrange)

        Spacer()

        Text("\(draftFee.formattedSats) total")
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        TextField("0", text: $draftRate)
          .font(.system(size: 40, weight: .regular, design: .monospaced))
          .keyboardType(.decimalPad)
          .focused($isRateFocused)
          .tint(Color.hbBitcoinOrange)
          .foregroundStyle(Color.hbTextPrimary)
          .onAppear { isRateFocused = true }
          .onChange(of: isRateFocused) {
            // Keyboard dismissed some other way — fall back to the priced rows
            if !isRateFocused {
              isTypingRate = false
            }
          }
          .onChange(of: draftRate) { _, newValue in
            let filtered = sanitizeRate(newValue)
            if filtered != newValue {
              draftRate = filtered
            }
            draftPreset = .custom
          }

        Text("sat/vB")
          .font(.hbMono(16))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 20)
        .fill(Color.hbBitcoinOrange.opacity(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: 20)
            .strokeBorder(Color.hbBitcoinOrange, lineWidth: 1.5)
        )
    )
  }

  /// The measured content plus room for the drag indicator. Applies to both
  /// layouts — the sheet is only ever as tall as what it is showing.
  private var sheetHeight: CGFloat {
    contentHeight + 20
  }

  private var commitTitle: String {
    guard isValidDraft else { return "Enter a fee rate" }
    let name = draftPreset == .custom
      ? "\(formatFeeRate(draftRateValue)) sat/vB"
      : draftPreset.displayName
    return "Use \(name) · \(draftFee.formattedSats)"
  }

  private func commit() {
    guard isValidDraft else { return }
    viewModel.selectedFeePreset = draftPreset
    viewModel.feeRateSatVb = draftRate
    viewModel.recalculateMaxIfNeeded()
    dismiss()
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Network fee")
        .font(.hbDisplay(22))
        .foregroundStyle(Color.hbTextPrimary)

      Spacer()

      Text("~\(viewModel.estimatedVsize) vB tx")
        .font(.hbMono(12))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  // MARK: - Rows

  private func presetRow(_ option: FeeOption) -> some View {
    let fee = viewModel.estimatedFee(for: option.rate)
    let isSelected = option.presets.contains(draftPreset)

    return Button(action: {
      draftPreset = option.primary
      draftRate = formatFeeRate(option.rate)
    }) {
      HStack(spacing: 12) {
        selectionIndicator(isSelected: isSelected)

        Text(option.title)
          .font(.hbHeadline)
          .foregroundStyle(Color.hbTextPrimary)
          .lineLimit(1)
          .layoutPriority(1)

        Spacer(minLength: 8)

        // A wallet with many UTXOs produces very wide sat figures — they
        // shrink rather than wrap or push the name into two lines.
        Text(fee.formattedSats)
          .font(.hbMonoBold(15))
          .foregroundStyle(Color.hbTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(minHeight: 56)
      .background(rowBackground(isSelected: isSelected))
    }
    .buttonStyle(.plain)
  }

  private var customRow: some View {
    let isSelected = draftPreset == .custom

    return HStack(spacing: 12) {
      selectionIndicator(isSelected: isSelected)

      Text(FeePreset.custom.displayName)
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)
        .lineLimit(1)
        .fixedSize()

      Spacer(minLength: 8)

      stepper
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(minHeight: 62)
    .background(rowBackground(isSelected: isSelected))
    .contentShape(Rectangle())
    .onTapGesture { selectCustom() }
  }

  /// A stepper rather than a bare number field — custom is the one place a
  /// user can silently strand a transaction, so nudging beats free typing.
  private var stepper: some View {
    HStack(spacing: 8) {
      stepButton("minus", enabled: draftRateValue > 0.1) {
        adjustRate(by: -stepSize)
      }

      // Tapping the value opens the typing layout rather than editing in
      // place — a second bound text field here would fight the big one.
      Button(action: startTyping) {
        Text(draftRate.isEmpty ? "0.0" : draftRate)
          .font(.hbMono(16))
          .foregroundStyle(draftRate.isEmpty ? Color.hbTextSecondary : Color.hbTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .frame(width: 58, height: 36)
          .background(Color.hbSurfaceElevated)
          .clipShape(RoundedRectangle(cornerRadius: 11))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      stepButton("plus", enabled: true) {
        adjustRate(by: stepSize)
      }
    }
  }

  private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(enabled ? Color.hbTextPrimary : Color.hbTextSecondary.opacity(0.4))
        .frame(width: 36, height: 36)
        .background(Color.hbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  /// Finer steps at low rates, whole steps once the rate is meaningful
  private var stepSize: Double {
    draftRateValue < 2 ? 0.1 : 1
  }

  private func adjustRate(by delta: Double) {
    selectCustom()
    let next = max(0.1, ((draftRateValue + delta) * 100).rounded() / 100)
    draftRate = formatFeeRate(next)
  }

  private func selectCustom() {
    draftPreset = .custom
  }

  private func startTyping() {
    draftPreset = .custom
    isTypingRate = true
  }

  private func stopTyping() {
    isRateFocused = false
    isTypingRate = false
  }

  private func selectionIndicator(isSelected: Bool) -> some View {
    ZStack {
      Circle()
        .fill(isSelected ? Color.hbBitcoinOrange : .clear)
        .frame(width: 22, height: 22)

      Circle()
        .strokeBorder(isSelected ? .clear : Color.hbBorder, lineWidth: 2)
        .frame(width: 22, height: 22)

      if isSelected {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white)
      }
    }
  }

  private func rowBackground(isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 18)
      .fill(isSelected ? Color.hbBitcoinOrange.opacity(0.12) : Color.hbSurface)
      .overlay(
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(
            isSelected ? Color.hbBitcoinOrange : Color.hbBorder,
            lineWidth: isSelected ? 1.5 : 0.5
          )
      )
  }

  private var totalRow: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Total with fee")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Text((viewModel.totalSendAmount + draftFee).formattedSats)
          .font(.hbMonoBold(17))
          .foregroundStyle(Color.hbTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }

      Spacer(minLength: 8)

      if fiatEnabled,
         let fiat = fiatService.formattedSatsToFiat(viewModel.totalSendAmount + draftFee)
      {
        Text("≈ \(fiat)")
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .padding(.top, 4)
    .overlay(alignment: .top) {
      Divider().overlay(Color.hbBorder).offset(y: -10)
    }
  }

  private func sanitizeRate(_ value: String) -> String {
    var filtered = value.filter { $0.isNumber || $0 == "." }
    if let dotIdx = filtered.firstIndex(of: ".") {
      let afterDot = filtered[filtered.index(after: dotIdx)...]
      filtered = String(filtered[...dotIdx]) + afterDot.filter { $0 != "." }
    }
    return filtered
  }
}

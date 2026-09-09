import SwiftUI

/// Fee selection presented as a sheet rather than an inline accordion, so the
/// send screen stays intact behind it and the Review button never gets pushed
/// off screen. Fast, Medium and Slow always all appear, even when the fee
/// source resolves two of them to the same rate.
struct SendFeeSheetView: View {
  @Bindable var viewModel: SendViewModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  /// Preset selected while the sheet is open; only committed on "Use …"
  @State private var draftPreset: FeePreset
  @State private var draftRate: String
  /// The Custom row's own value, independent of the selected preset.
  @State private var customRate: String
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
    _customRate = State(
      initialValue: viewModel.selectedFeePreset == .custom
        ? viewModel.feeRateSatVb
        : Self.defaultCustomRate
    )
  }

  /// Where Custom starts when the user hasn't set one
  private static let defaultCustomRate = "1.0"

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

  private let speedPresets: [FeePreset] = [.fast, .medium, .slow]

  private func rate(for preset: FeePreset) -> Double {
    preset.rate(from: viewModel.recommendedFees) ?? 0
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
          ForEach(speedPresets, id: \.self) { preset in
            presetRow(preset)
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
    .padding(.top, 24)
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
      ForEach(speedPresets, id: \.self) { preset in
        Button(action: {
          draftPreset = preset
          draftRate = formatFeeRate(rate(for: preset))
          stopTyping()
        }) {
          VStack(spacing: 4) {
            Text(preset.displayName)
              .font(.hbBody(13).weight(.bold))
              .foregroundStyle(Color.hbTextPrimary)
            Text(formatFeeRate(rate(for: preset)))
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
            customRate = draftRate
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
      Text("Network Fee")
        .font(.hbDisplay(22))
        .foregroundStyle(Color.hbTextPrimary)

      Spacer()

      Text("~\(viewModel.estimatedVsize) vB tx")
        .font(.hbMono(12))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  // MARK: - Rows

  private func presetRow(_ preset: FeePreset) -> some View {
    let presetRate = rate(for: preset)
    let isSelected = draftPreset == preset

    return Button(action: {
      draftPreset = preset
      draftRate = formatFeeRate(presetRate)
    }) {
      HStack(spacing: 12) {
        selectionIndicator(isSelected: isSelected)

        Text(preset.displayName)
          .font(.hbHeadline)
          .foregroundStyle(Color.hbTextPrimary)
          .lineLimit(1)
          .layoutPriority(1)

        Spacer(minLength: 8)

        Text("\(formatFeeRate(presetRate)) sat/vB")
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

      rateField
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(minHeight: 62)
    .background(rowBackground(isSelected: isSelected))
    .contentShape(Rectangle())
    .onTapGesture { selectCustom() }
  }

  /// Tapping the value opens the typing layout rather than editing in place —
  /// a second bound text field here would fight the big one.
  private var rateField: some View {
    HStack(spacing: 8) {
      Button(action: startTyping) {
        Text(customRate.isEmpty ? Self.defaultCustomRate : customRate)
          .font(.hbMono(18))
          .foregroundStyle(draftRate.isEmpty ? Color.hbTextSecondary : Color.hbTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .frame(width: 96, height: 44)
          .background(Color.hbSurfaceElevated)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Text("sat/vB")
        .font(.hbMono(13))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  private func selectCustom() {
    draftPreset = .custom
    draftRate = customRate
  }

  private func startTyping() {
    selectCustom()
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
        Text("Total fee")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Text(draftFee.formattedSats)
          .font(.hbMonoBold(17))
          .foregroundStyle(Color.hbTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }

      Spacer(minLength: 8)

      if fiatEnabled, let fiat = fiatService.formattedSatsToFiat(draftFee) {
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

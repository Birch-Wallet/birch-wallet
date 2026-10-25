import SwiftUI

/// Import cosigners: a folder tab per cosigner on top of the open cosigner's
/// form. Tabs switch freely; only Next validates.
struct CosignerImportView: View {
  @Bindable var viewModel: SetupWizardViewModel
  @State private var showScanner = false
  @Environment(\.setupLayout) private var layout

  private typealias Field = SetupWizardViewModel.CosignerField

  private static let topID = "cosigner-top"

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 24) {
          title
            .id(Self.topID)

          VStack(spacing: 0) {
            CosignerTabs(viewModel: viewModel)
              .zIndex(1)
            form
              .hbCard(squareTop: true)
          }
          .padding(.horizontal, 24)

          // Navigation
          HStack(spacing: 16) {
            Button(action: { viewModel.goBack() }) {
              Text("Back")
                .hbCompactSecondaryButton()
            }

            Spacer()

            // Outlined until every cosigner is complete, but never disabled:
            // Next is what shows the user what is missing
            Button(action: { goNext(proxy: proxy) }) {
              Text("Next")
                .hbCompactPrimaryButton(viewModel.allCosignersComplete ? .filled : .outlined)
            }
          }
          .padding(.horizontal, 24)
          .padding(.bottom, 32)
        }
        .padding(.top, 16)
        .padding(.top, layout == .column ? 40 : 0)
        .setupReadableWidth()
        .contentShape(Rectangle())
        .onTapGesture(perform: dismissKeyboard)
      }
      .scrollDismissesKeyboard(.interactively)
    }
    .sheet(isPresented: $showScanner) {
      URScannerSheet(expectedTypes: [.hdKey], onCancel: { showScanner = false }) { result in
        handleScanResult(result)
        showScanner = false
      }
      .birchSheet()
    }
    // Editing a field clears its flag. Switching cosigners changes no value, so
    // a cosigner opened flagged keeps its flags.
    .onChange(of: viewModel.cosignerXpubs) { old, new in
      viewModel.clearErrors(.xpub, editedFrom: old, to: new)
    }
    .onChange(of: viewModel.cosignerFingerprints) { old, new in
      viewModel.clearErrors(.fingerprint, editedFrom: old, to: new)
    }
    .onChange(of: viewModel.cosignerDerivationPaths) { old, new in
      viewModel.clearErrors(.path, editedFrom: old, to: new)
    }
  }

  private var title: some View {
    Text("Import Cosigners")
      .font(.hbDisplay(28))
      .foregroundStyle(Color.hbTextPrimary)
  }

  // MARK: - Form

  @ViewBuilder
  private var form: some View {
    let index = viewModel.currentCosignerIndex
    if index < viewModel.cosignerXpubs.count, index < viewModel.cosignerFingerprints.count,
       index < viewModel.cosignerLabels.count, index < viewModel.cosignerDerivationPaths.count
    {
      let errors = viewModel.cosignerErrors[index] ?? [:]
      VStack(spacing: 16) {
        labelField(index)
        xpubField(index, error: errors[.xpub])
        fingerprintField(index, error: errors[.fingerprint])
        pathField(index, error: errors[.path])
      }
    }
  }

  private func labelField(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Label")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      TextField("Cosigner name", text: $viewModel.cosignerLabels[index])
        .font(.hbBody())
        .padding(12)
        .birchCard(.nested)
        .foregroundStyle(Color.hbTextPrimary)
    }
  }

  /// The key, with the format toggle beside its label and Scan QR and Paste
  /// under it as in-card utilities
  private func xpubField(_ index: Int, error: String?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Extended Public Key")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        Button(action: toggleXpubFormat) {
          Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.green)
        }
        .accessibilityLabel("Switch key format")
      }

      CharWrappingTextEditor(text: $viewModel.cosignerXpubs[index], fontSize: 12, minHeight: 80)
        .padding(12)
        .birchCard(.nested)
        .hbFieldError(error)

      HStack(spacing: 8) {
        HBTonalButton(title: "Scan QR", systemImage: "qrcode.viewfinder") {
          showScanner = true
        }
        HBTonalButton(title: "Paste", systemImage: "doc.on.clipboard", neutral: true, action: pasteFromClipboard)
      }
      .padding(.top, 6)
    }
    .id(Field.xpub)
  }

  private func fingerprintField(_ index: Int, error: String?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Master Fingerprint (8 hex chars)")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      TextField("e.g. 73c5da0a", text: $viewModel.cosignerFingerprints[index])
        .font(.hbMono())
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(12)
        .birchCard(.nested)
        .foregroundStyle(Color.hbTextPrimary)
        .hbFieldError(error)
    }
    .id(Field.fingerprint)
  }

  private func pathField(_ index: Int, error: String?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Derivation Path")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      let path = viewModel.cosignerDerivationPaths[index]
      Text(path.isEmpty ? "–" : path)
        .font(.hbMono())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .birchCard(.nested)
        .foregroundStyle(Color.hbTextPrimary)
        .hbFieldError(error)
    }
    .id(Field.path)
  }

  // MARK: - Actions

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  private func pasteFromClipboard() {
    if let text = UIPasteboard.general.string {
      let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let isTestnet = viewModel.network != .mainnet
      if let normalized = URService.normalizeXpub(raw, isTestnet: isTestnet) {
        viewModel.cosignerXpubs[viewModel.currentCosignerIndex] = normalized
      } else {
        viewModel.cosignerXpubs[viewModel.currentCosignerIndex] = raw
      }
    }
  }

  private func toggleXpubFormat() {
    let idx = viewModel.currentCosignerIndex
    let current = viewModel.cosignerXpubs[idx].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !current.isEmpty else { return }

    let isTestnet = viewModel.network != .mainnet
    if let toggled = URService.toggleXpubFormat(current, isTestnet: isTestnet) {
      viewModel.cosignerXpubs[idx] = toggled
    }
  }

  /// Next: flags the open cosigner when it is incomplete, otherwise opens the
  /// next incomplete one, or goes on to Verify wallet once all are complete.
  /// What was flagged is scrolled into view and read out.
  private func goNext(proxy: ScrollViewProxy) {
    dismissKeyboard()
    switch viewModel.goToNextCosigner() {
    case let .flag(problems):
      let first = [Field.xpub, .fingerprint, .path].first { problems[$0] != nil }
      if let first {
        withAnimation {
          proxy.scrollTo(first, anchor: .center)
        }
        AccessibilityNotification.Announcement(problems[first] ?? "").post()
      }
    case let .open(index, flagged):
      withAnimation {
        proxy.scrollTo(Self.topID, anchor: .top)
      }
      var announcement = "Cosigner \(index + 1) of \(viewModel.totalCosigners)"
      if flagged, let problem = viewModel.cosignerErrors[index]?[.xpub] ?? viewModel.cosignerErrors[index]?[.fingerprint] {
        announcement += ". \(problem)"
      }
      AccessibilityNotification.Announcement(announcement).post()
    case .finish:
      break
    }
  }

  private func handleScanResult(_ result: AppURResult) {
    let idx = viewModel.currentCosignerIndex
    switch result {
    case .hdKey(var xpub, let fingerprint, let derivationPath):
      // Validate derivation path network before accepting the scan
      if !derivationPath.isEmpty, let error = viewModel.validateDerivationPath(derivationPath) {
        viewModel.cosignerErrors[idx, default: [:]][.xpub] = error
        return
      }

      // Auto-convert any xpub/tpub/Zpub/Vpub to the standard format for the network
      let isTestnet = viewModel.network != .mainnet
      if let normalized = URService.normalizeXpub(xpub, isTestnet: isTestnet) {
        xpub = normalized
      }

      viewModel.cosignerXpubs[idx] = xpub
      if !fingerprint.isEmpty {
        viewModel.cosignerFingerprints[idx] = fingerprint
      }
      if !derivationPath.isEmpty {
        viewModel.cosignerDerivationPaths[idx] = derivationPath
      }
    default:
      viewModel.cosignerErrors[idx, default: [:]][.xpub] = "Unexpected QR code type. Expected crypto-hdkey or crypto-account."
    }
  }
}

// MARK: - Tabs

/// One folder tab per cosigner, on top of the form. The open tab stands taller
/// and joins the card; a check marks a cosigner whose fields all validate.
/// Past six cosigners the tabs scroll sideways.
private struct CosignerTabs: View {
  @Bindable var viewModel: SetupWizardViewModel

  private static let visibleTabs = 6

  var body: some View {
    if viewModel.totalCosigners > Self.visibleTabs {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          tabs(fixedWidth: true)
        }
        // Keep the open tab's shadow, which reaches past the row
        .scrollClipDisabled()
        .onAppear {
          proxy.scrollTo(viewModel.currentCosignerIndex)
        }
        .onChange(of: viewModel.currentCosignerIndex) {
          withAnimation {
            proxy.scrollTo(viewModel.currentCosignerIndex)
          }
        }
      }
    } else {
      tabs(fixedWidth: false)
    }
  }

  private func tabs(fixedWidth: Bool) -> some View {
    HStack(alignment: .bottom, spacing: 4) {
      ForEach(0 ..< viewModel.totalCosigners, id: \.self) { index in
        let isOpen = index == viewModel.currentCosignerIndex
        sized(
          CosignerTab(
            number: index + 1,
            isOpen: isOpen,
            isComplete: viewModel.isCosignerComplete(index),
            action: { viewModel.openCosigner(index) },
          ),
          fixedWidth: fixedWidth,
        )
        .zIndex(isOpen ? 1 : 0)
        .id(index)
      }
    }
  }

  /// Equal shares of the row, or a sixth of it each when the tabs scroll
  @ViewBuilder
  private func sized(_ tab: some View, fixedWidth: Bool) -> some View {
    if fixedWidth {
      tab.containerRelativeFrame(.horizontal, count: Self.visibleTabs, spacing: 4)
    } else {
      tab.frame(maxWidth: .infinity)
    }
  }
}

private struct CosignerTab: View {
  @Environment(\.colorScheme) private var scheme
  let number: Int
  let isOpen: Bool
  let isComplete: Bool
  let action: () -> Void

  private var shape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
  }

  /// Shade for the tabs' shadows: black in dark mode, a warm brown in light
  private var shadeColor: Color {
    scheme == .dark ? .black : Color(red: 70 / 255, green: 55 / 255, blue: 30 / 255)
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 16))
          .foregroundStyle(isComplete ? Color.hbSuccess : isOpen ? Color.hbTextPrimary : Color.hbTextSecondary)
        Text("\(number)")
          .font(.hbBody(17).weight(isOpen ? .semibold : .regular))
          .monospacedDigit()
          .foregroundStyle(isOpen ? Color.hbTextPrimary : Color.hbTextSecondary)
      }
      .lineLimit(1)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity)
      .frame(height: isOpen ? 46 : 42)
      .background { background }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Cosigner \(number)")
    .accessibilityValue(isComplete ? "Complete" : "Incomplete")
    .accessibilityAddTraits(isOpen ? .isSelected : [])
    .accessibilityIdentifier("Cosigner \(number) tab")
  }

  @ViewBuilder
  private var background: some View {
    if isOpen {
      // Lit from above: a sheen that fades into the card it joins, and a soft
      // shadow up and onto its neighbours, cut off at its base so the card
      // below stays clean
      let sheen = Color.hbSurface.mix(with: .white, by: scheme == .dark ? 0.1 : 0.55)
      ZStack {
        shape
          .fill(Color.hbSurface)
          .shadow(color: shadeColor.opacity(scheme == .dark ? 0.5 : 0.16), radius: 5, y: -1)
          .mask {
            Rectangle().padding(EdgeInsets(top: -20, leading: -20, bottom: 0, trailing: -20))
          }
        shape.fill(
          LinearGradient(
            stops: [.init(color: sheen, location: 0), .init(color: Color.hbSurface, location: 0.8)],
            startPoint: .top,
            endPoint: .bottom,
          ),
        )
      }
    } else {
      // Behind the card: halfway between card and ground, with the card's
      // shadow across the base
      let shade = scheme == .dark ? 0.55 : 0.16
      shape
        .fill(Color.hbBackground)
        .overlay(shape.fill(Color.hbSurface.opacity(0.45)))
        .overlay(alignment: .bottom) {
          LinearGradient(
            stops: [
              .init(color: shadeColor.opacity(0), location: 0),
              .init(color: shadeColor.opacity(shade * 0.16), location: 0.5),
              .init(color: shadeColor.opacity(shade * 0.5), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom,
          )
          .frame(height: 9)
        }
        .clipShape(shape)
    }
  }
}

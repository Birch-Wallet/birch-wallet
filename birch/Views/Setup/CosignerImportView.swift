import SwiftUI

struct CosignerImportView: View {
  @Bindable var viewModel: SetupWizardViewModel
  @State private var validationError: String?
  @State private var showScanner = false
  @Environment(\.setupLayout) private var layout

  var body: some View {
    Group {
      if layout == .twoColumn {
        twoColumnBody
      } else {
        singleColumnBody
      }
    }
    .sheet(isPresented: $showScanner) {
      URScannerSheet(expectedTypes: [.hdKey], onCancel: { showScanner = false }) { result in
        handleScanResult(result)
        showScanner = false
      }
      .birchSheet()
    }
  }

  private var singleColumnBody: some View {
    ScrollView {
      VStack(spacing: 24) {
        title

        positionLabel

        // Cosigner cards overview
        cosignerSlots
          .padding(.horizontal, 24)

        // Current cosigner form
        VStack(spacing: 16) {
          identityFields
          xpubField(fillsHeight: false)
          validationMessage
        }
        .hbCard()
        .padding(.horizontal, 24)

        // Navigation
        HStack(spacing: 16) {
          backButton

          Spacer()

          Button(action: goNext) {
            Text(nextTitle)
              .font(.hbHeadline)
              .foregroundStyle(.white)
              .padding(.horizontal, 24)
              .padding(.vertical, 14)
              .background(viewModel.currentCosignerComplete ? Color.hbBitcoinOrange : Color.hbBorder)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .disabled(!viewModel.currentCosignerComplete)
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

  /// Left: which cosigner this is and who it belongs to, with Back at the
  /// bottom. Right: the xpub, filling the height, with Next below it.
  private var twoColumnBody: some View {
    SetupTwoColumn {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          title
          Spacer()
          positionLabel
        }
        cosignerSlots
        VStack(spacing: 16) {
          identityFields
        }
        .hbCard()
        Spacer(minLength: 16)
        backButton
      }
      .padding(.vertical, 16)
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
    } trailing: {
      VStack(spacing: 12) {
        VStack(spacing: 16) {
          xpubField(fillsHeight: true)
          validationMessage
        }
        .hbCard()
        Button(action: goNext) {
          Text(nextTitle)
            .hbPrimaryButton(isEnabled: viewModel.currentCosignerComplete)
        }
        .disabled(!viewModel.currentCosignerComplete)
      }
      // Start the xpub level with the content under the title.
      .padding(.top, 56)
      .padding(.bottom, 16)
    }
  }

  private var title: some View {
    Text("Import Cosigners")
      .font(.hbDisplay(28))
      .foregroundStyle(Color.hbTextPrimary)
  }

  private var positionLabel: some View {
    Text("Cosigner \(viewModel.currentCosignerIndex + 1) of \(viewModel.totalCosigners)")
      .font(.hbBody(15))
      .foregroundStyle(Color.hbTextSecondary)
  }

  private var nextTitle: String {
    viewModel.currentCosignerIndex < viewModel.totalCosigners - 1 ? "Next Cosigner" : "Continue"
  }

  private var cosignerSlots: some View {
    HStack(spacing: 8) {
      ForEach(0 ..< viewModel.totalCosigners, id: \.self) { index in
        CosignerSlot(
          index: index,
          isCurrent: index == viewModel.currentCosignerIndex,
          isComplete: !viewModel.cosignerXpubs[index].isEmpty
        )
      }
    }
  }

  @ViewBuilder
  private var identityFields: some View {
    // Label
    VStack(alignment: .leading, spacing: 6) {
      Text("Label")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      TextField("Cosigner name", text: $viewModel.cosignerLabels[viewModel.currentCosignerIndex])
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

      TextField("e.g. 73c5da0a", text: $viewModel.cosignerFingerprints[viewModel.currentCosignerIndex])
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

      Text(viewModel.cosignerDerivationPaths[viewModel.currentCosignerIndex].isEmpty ? "–" : viewModel.cosignerDerivationPaths[viewModel.currentCosignerIndex])
        .font(.hbMono())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .birchCard(.nested)
        .foregroundStyle(Color.hbTextPrimary)
    }
  }

  private func xpubField(fillsHeight: Bool) -> some View {
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
        .padding(.trailing, 12)

        Button(action: pasteFromClipboard) {
          Label("Paste", systemImage: "doc.on.clipboard")
            .font(.hbLabel())
            .foregroundStyle(Color.hbSteelBlue)
        }
      }

      TextEditor(text: $viewModel.cosignerXpubs[viewModel.currentCosignerIndex])
        .font(.hbMono(12))
        .frame(minHeight: 80, maxHeight: fillsHeight ? .infinity : nil)
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

  @ViewBuilder
  private var validationMessage: some View {
    if let error = validationError {
      Text(error)
        .font(.hbLabel())
        .foregroundStyle(Color.hbError)
    }
  }

  private var backButton: some View {
    Button(action: goBack) {
      Text(viewModel.currentCosignerIndex > 0 ? "Previous" : "Back")
        .font(.hbBody(16))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

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

  private func goBack() {
    if viewModel.currentCosignerIndex > 0 {
      viewModel.currentCosignerIndex -= 1
    } else {
      viewModel.goBack()
    }
  }

  private func goNext() {
    // Validate current cosigner
    let idx = viewModel.currentCosignerIndex
    if let error = viewModel.validateCosignerXpub(viewModel.cosignerXpubs[idx], at: idx) {
      validationError = error
      return
    }
    if let error = viewModel.validateFingerprint(viewModel.cosignerFingerprints[idx]) {
      validationError = error
      return
    }
    if let error = viewModel.validateDerivationPath(viewModel.cosignerDerivationPaths[idx]) {
      validationError = error
      return
    }

    validationError = nil

    if viewModel.currentCosignerIndex < viewModel.totalCosigners - 1 {
      viewModel.currentCosignerIndex += 1
    } else {
      viewModel.goToNext()
    }
  }

  private func handleScanResult(_ result: AppURResult) {
    switch result {
    case .hdKey(var xpub, let fingerprint, let derivationPath):
      let idx = viewModel.currentCosignerIndex

      // Validate derivation path network before accepting the scan
      if !derivationPath.isEmpty {
        if let error = viewModel.validateDerivationPath(derivationPath) {
          validationError = error
          return
        }
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
      validationError = "Unexpected QR code type. Expected crypto-hdkey or crypto-account."
    }
  }
}

private struct CosignerSlot: View {
  let index: Int
  let isCurrent: Bool
  let isComplete: Bool

  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        Color.clear
          .frame(height: 44)
          .birchSelected(isCurrent || isComplete, ring: isCurrent)

        if isComplete {
          Image(systemName: "lock.fill")
            .font(.system(size: 16))
            .foregroundStyle(Color.hbBitcoinOrange)
        } else {
          Image(systemName: "lock.open")
            .font(.system(size: 16))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }

      Text("\(index + 1)")
        .font(.hbLabel(11))
        .foregroundStyle(isCurrent ? Color.hbBitcoinOrange : Color.hbTextSecondary)
    }
  }
}

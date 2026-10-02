import SwiftUI

struct DescriptorImportView: View {
  @Bindable var viewModel: SetupWizardViewModel
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
      URScannerSheet(expectedTypes: [.descriptor], onCancel: { showScanner = false }) { result in
        if case let .descriptor(text) = result {
          viewModel.importedDescriptorText = text
        }
        showScanner = false
      }
      .birchSheet()
    }
  }

  private var singleColumnBody: some View {
    ScrollView {
      VStack(spacing: 24) {
        title
          .padding(.top, 16)

        subtitle
          .multilineTextAlignment(.center)

        descriptorCard(fillsHeight: false)
          .padding(.horizontal, 24)

        scanButton
          .padding(.horizontal, 24)

        SetupNetworkPicker(viewModel: viewModel)
          .padding(.horizontal, 24)

        errors
          .padding(.horizontal, 24)

        // Electrum server
        ElectrumServerSetupSection(viewModel: viewModel, initiallyExpanded: viewModel.network == .mainnet)
          .padding(.horizontal, 24)

        // Advanced
        WalletAdvancedSetupSection(viewModel: viewModel)
          .padding(.horizontal, 24)

        HStack(spacing: 16) {
          backButton

          Spacer()

          Button(action: { viewModel.goToNext() }) {
            Text("Import")
              .font(.hbHeadline)
              .foregroundStyle(.white)
              .padding(.horizontal, 32)
              .padding(.vertical, 14)
              .background(canImport ? Color.hbBitcoinOrange : Color.hbBorder)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .disabled(!canImport)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
      .padding(.top, layout == .column ? 40 : 0)
      .setupReadableWidth()
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  /// Left: the step, scanning and the settings, with Back at the bottom.
  /// Right: the descriptor itself, filling the height, with Import below it.
  private var twoColumnBody: some View {
    SetupTwoColumn {
      VStack(alignment: .leading, spacing: 16) {
        title
        subtitle
          .multilineTextAlignment(.leading)
        scanButton
        SetupNetworkPicker(viewModel: viewModel)
        ElectrumServerSetupSection(viewModel: viewModel, initiallyExpanded: viewModel.network == .mainnet)
        WalletAdvancedSetupSection(viewModel: viewModel)
        Spacer(minLength: 16)
        backButton
      }
      .padding(.vertical, 16)
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
    } trailing: {
      VStack(spacing: 12) {
        descriptorCard(fillsHeight: true)
        errors
        Button(action: { viewModel.goToNext() }) {
          Text("Import")
            .hbPrimaryButton(isEnabled: canImport)
        }
        .disabled(!canImport)
      }
      .padding(.vertical, 16)
    }
  }

  private var canImport: Bool {
    !viewModel.importedDescriptorText.isEmpty && viewModel.descriptorNetworkMismatchError == nil
  }

  private var title: some View {
    Text("Import Descriptor")
      .font(.hbDisplay(28))
      .foregroundStyle(Color.hbTextPrimary)
  }

  private var subtitle: some View {
    Text("Paste or scan a multisig output descriptor")
      .font(.hbBody(15))
      .foregroundStyle(Color.hbTextSecondary)
  }

  private func descriptorCard(fillsHeight: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Output Descriptor")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        Button(action: {
          if let text = UIPasteboard.general.string {
            viewModel.importedDescriptorText = text.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }) {
          Label("Paste", systemImage: "doc.on.clipboard")
            .font(.hbLabel())
            .foregroundStyle(Color.hbSteelBlue)
        }
      }

      TextEditor(text: $viewModel.importedDescriptorText)
        .font(.hbMono(11))
        .frame(minHeight: 120, maxHeight: fillsHeight ? .infinity : nil)
        .scrollContentBackground(.hidden)
        .padding(12)
        .birchCard(.nested)
        .foregroundStyle(Color.hbTextPrimary)
        .onChange(of: viewModel.importedDescriptorText) {
          viewModel.importDescriptorError = nil
        }

      Text("Expected format: wsh(sortedmulti(M,[fp/path]xpub/0/*,...))")
        .font(.hbMono(10))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .hbCard()
  }

  private var scanButton: some View {
    Button(action: { showScanner = true }) {
      Label("Scan Descriptor QR", systemImage: "qrcode.viewfinder")
        .hbSecondaryButton()
    }
  }

  @ViewBuilder
  private var errors: some View {
    if let mismatchError = viewModel.descriptorNetworkMismatchError {
      Text(mismatchError)
        .font(.hbLabel(13))
        .foregroundStyle(Color.hbError)
        .multilineTextAlignment(.center)
    }

    if let importError = viewModel.importDescriptorError {
      Text(importError)
        .font(.hbBody(13))
        .foregroundStyle(Color.hbError)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.hbError.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  private var backButton: some View {
    Button(action: { viewModel.goBack() }) {
      Text("Back")
        .font(.hbBody(16))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

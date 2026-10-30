import SwiftUI

struct DescriptorImportView: View {
  @Bindable var viewModel: SetupWizardViewModel
  /// Saves the wallet once the descriptor is read
  let onImport: () -> Void
  @State private var showScanner = false
  @Environment(\.setupLayout) private var layout

  private static let descriptorFieldID = "descriptor"

  var body: some View {
    ScrollViewReader { proxy in
      Group {
        if layout == .twoColumn {
          twoColumnBody(proxy: proxy)
        } else {
          singleColumnBody(proxy: proxy)
        }
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

  private func singleColumnBody(proxy: ScrollViewProxy) -> some View {
    ScrollView {
      VStack(spacing: 24) {
        title
          .padding(.top, 16)

        subtitle
          .multilineTextAlignment(.center)

        descriptorCard(fillsHeight: false)
          .padding(.horizontal, 24)

        settings
          .padding(.horizontal, 24)

        HStack(spacing: 16) {
          backButton

          Spacer()

          Button(action: { importDescriptor(proxy: proxy) }) {
            Text("Import")
              .hbCompactPrimaryButton(canImport ? .filled : .disabled)
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

  /// Left: the step and the settings, with Back at the bottom. Right: the
  /// descriptor itself, filling the height, with Import below it.
  private func twoColumnBody(proxy: ScrollViewProxy) -> some View {
    SetupTwoColumn {
      VStack(alignment: .leading, spacing: 16) {
        title
        subtitle
          .multilineTextAlignment(.leading)
        settings
        Spacer(minLength: 16)
        backButton
      }
      .padding(.vertical, 16)
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
    } trailing: {
      VStack(spacing: 12) {
        descriptorCard(fillsHeight: true)
        Button(action: { importDescriptor(proxy: proxy) }) {
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

  @ViewBuilder
  private var settings: some View {
    WalletNameNetworkCard(viewModel: viewModel)
    ElectrumServerSetupSection(viewModel: viewModel)
    WalletAdvancedSetupSection(viewModel: viewModel)
  }

  /// The descriptor, then Scan QR and Paste as in-card utilities. A failed
  /// import or a descriptor for the other network flags the field.
  private func descriptorCard(fillsHeight: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Output Descriptor")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      CharWrappingTextEditor(
        text: $viewModel.importedDescriptorText,
        fontSize: 11,
        placeholder: "wsh(sortedmulti(M,[fp/path]xpub/0/*,...))",
        minHeight: 120,
        fillsHeight: fillsHeight,
      )
      .padding(12)
      .birchCard(.nested)
      .hbFieldError(viewModel.importDescriptorError ?? viewModel.descriptorNetworkMismatchError)
      .id(Self.descriptorFieldID)
      .onChange(of: viewModel.importedDescriptorText) {
        viewModel.importDescriptorError = nil
      }

      HStack(spacing: 8) {
        HBTonalButton(title: "Scan QR", systemImage: "qrcode.viewfinder") {
          showScanner = true
        }
        HBTonalButton(title: "Paste", systemImage: "doc.on.clipboard", neutral: true) {
          if let text = UIPasteboard.general.string {
            viewModel.importedDescriptorText = text.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
      }
      .padding(.top, 4)
    }
    .hbCard()
  }

  private var backButton: some View {
    Button(action: { viewModel.goBack() }) {
      Text("Back")
        .hbCompactSecondaryButton()
    }
  }

  /// Saves the wallet, or scrolls to what stopped it and reads out why
  private func importDescriptor(proxy: ScrollViewProxy) {
    dismissKeyboard()
    if viewModel.goToNext() {
      onImport()
      return
    }
    guard let importError = viewModel.importDescriptorError else { return }
    withAnimation {
      proxy.scrollTo(Self.descriptorFieldID, anchor: .top)
    }
    AccessibilityNotification.Announcement(importError).post()
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

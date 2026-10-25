import SwiftUI

/// Import cosigners: a folder tab per cosigner on top of the open cosigner's
/// form (`CosignerForm`). Tabs switch freely; only Next validates.
struct CosignerImportView: View {
  @Bindable var viewModel: SetupWizardViewModel
  @Environment(\.setupLayout) private var layout

  private static let topID = "cosigner-top"

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 24) {
          title
            .id(Self.topID)

          CosignerForm(viewModel: viewModel)
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
  }

  private var title: some View {
    Text("Import Cosigners")
      .font(.hbDisplay(28))
      .foregroundStyle(Color.hbTextPrimary)
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  /// Next: flags the open cosigner when it is incomplete, otherwise opens the
  /// next incomplete one, or goes on to Verify wallet once all are complete.
  /// What was flagged is scrolled into view and read out.
  private func goNext(proxy: ScrollViewProxy) {
    dismissKeyboard()
    CosignerForm.reveal(viewModel.goToNextCosigner(), viewModel: viewModel, proxy: proxy, topID: Self.topID)
  }
}

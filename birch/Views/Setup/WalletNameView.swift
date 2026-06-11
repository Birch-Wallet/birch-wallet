import SwiftUI

struct WalletNameView: View {
  @Bindable var viewModel: SetupWizardViewModel
  var onSave: (() -> Void)?

  var body: some View {
    VStack(spacing: 32) {
      Spacer()

      Image(systemName: "wallet.pass.fill")
        .font(.system(size: 48))
        .foregroundStyle(Color.hbBitcoinOrange)

      Text("Name Your Wallet")
        .font(.hbDisplay(28))
        .foregroundStyle(Color.hbTextPrimary)

      VStack(alignment: .leading, spacing: 6) {
        Text("Wallet Name")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        TextField("My Wallet", text: $viewModel.walletName)
          .font(.hbBody(18))
          .padding(14)
          .background(Color.hbSurfaceElevated)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .foregroundStyle(Color.hbTextPrimary)
      }
      .padding(.horizontal, 24)
      // Cap the input column to a readable width so it centers under the title
      // on wide layouts (iPad). On iPhone the screen is narrower than this cap,
      // so the field stays full-width as before.
      .frame(maxWidth: 480)

      Spacer()

      HStack(spacing: 16) {
        if viewModel.creationMode == .createNew {
          Button(action: { viewModel.goBack() }) {
            Text("Back")
              .font(.hbBody(16))
              .foregroundStyle(Color.hbTextSecondary)
          }
        }

        Spacer()

        Button(action: {
          if viewModel.creationMode == .importDescriptor, let onSave {
            onSave()
          } else {
            viewModel.goToNext()
          }
        }) {
          Text(viewModel.creationMode == .importDescriptor ? "Create Wallet" : "Next")
            .font(.hbHeadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(Color.hbBitcoinOrange)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
      }
      .padding(.horizontal, 24)
      // Match the input column width so the Back/Next buttons stay aligned with
      // the centered field on wide layouts instead of floating to the corners.
      .frame(maxWidth: 480)
      .padding(.bottom, 32)
    }
  }
}

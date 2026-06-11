import SwiftUI

struct WalletCreationChoiceView: View {
  @Bindable var viewModel: SetupWizardViewModel

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      Text("Wallet Setup")
        .font(.hbDisplay(28))
        .foregroundStyle(Color.hbTextPrimary)

      Text("Choose how to configure your multisig wallet")
        .font(.hbBody(15))
        .foregroundStyle(Color.hbTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      HStack(spacing: 6) {
        Image(systemName: "info.circle")
          .font(.system(size: 12))
        Text("Only BIP-67 P2WSH script type is supported")
          .font(.hbLabel(12))
      }
      .foregroundStyle(Color.hbTextSecondary)
      .padding(.horizontal, 32)

      VStack(spacing: 16) {
        ChoiceCard(
          icon: "plus.circle.fill",
          title: "Create New Wallet",
          subtitle: "Setup M-of-N multisig by importing cosigner xpubs from one or more air-gapped signing devices",
          isSelected: viewModel.creationMode == .createNew
        ) {
          viewModel.creationMode = .createNew
          viewModel.goToNext()
        }

        ChoiceCard(
          icon: "square.and.arrow.down.fill",
          title: "Import Descriptor",
          subtitle: "Import an existing wallet via output descriptor from a printed backup or another coordinator",
          isSelected: viewModel.creationMode == .importDescriptor
        ) {
          viewModel.creationMode = .importDescriptor
          viewModel.goToNext()
        }
      }
      .padding(.horizontal, 24)
      // Cap the choice cards to a readable width so they center on wide layouts
      // (iPad) instead of stretching edge-to-edge. On iPhone the screen is
      // narrower than this cap, so the cards stay full-width as before.
      .frame(maxWidth: 480)

      Spacer()

      Button(action: { viewModel.goBack() }) {
        Text("Back")
          .font(.hbBody(16))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .padding(.bottom, 32)
    }
  }
}

private struct ChoiceCard: View {
  let icon: String
  let title: String
  let subtitle: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Image(systemName: icon)
          .font(.system(size: 28))
          .foregroundStyle(Color.hbBitcoinOrange)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.hbHeadline)
            .foregroundStyle(Color.hbTextPrimary)

          Text(subtitle)
            .font(.hbLabel(13))
            .foregroundStyle(Color.hbTextSecondary)
            .multilineTextAlignment(.leading)
        }

        Spacer()

        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .padding(20)
      .background(Color.hbSurface)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Color.hbBorder, lineWidth: 0.5)
      )
    }
  }
}

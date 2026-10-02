import SwiftUI

struct WalletCreationChoiceView: View {
  @Bindable var viewModel: SetupWizardViewModel
  @Environment(\.setupLayout) private var layout

  var body: some View {
    if layout == .twoColumn {
      twoColumnBody
    } else {
      singleColumnBody
    }
  }

  private var singleColumnBody: some View {
    VStack(spacing: 24) {
      Spacer()

      title

      subtitle
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      scriptTypeNote
        .padding(.horizontal, 32)

      choiceCards
        .padding(.horizontal, 24)

      // Phone: the action sits at the bottom. Readable column: it stays with
      // the content, and the group centers together.
      if layout == .column {
        Color.clear.frame(height: 24)
      } else {
        Spacer()
      }

      backButton
        .padding(.bottom, 32)

      if layout == .column {
        Spacer()
      }
    }
    .setupReadableWidth()
  }

  /// Left: what this step is, with Back at the bottom. Right: the two choices.
  private var twoColumnBody: some View {
    SetupTwoColumn {
      VStack(alignment: .leading, spacing: 16) {
        Spacer(minLength: 16)
        title
        subtitle
          .multilineTextAlignment(.leading)
        scriptTypeNote
        Spacer(minLength: 16)
        backButton
          .padding(.bottom, 16)
      }
    } trailing: {
      VStack {
        Spacer(minLength: 16)
        choiceCards
        Spacer(minLength: 16)
      }
    }
  }

  private var title: some View {
    Text("Wallet Setup")
      .font(.hbDisplay(28))
      .foregroundStyle(Color.hbTextPrimary)
  }

  private var subtitle: some View {
    Text("Choose how to configure your multisig wallet")
      .font(.hbBody(15))
      .foregroundStyle(Color.hbTextSecondary)
  }

  private var scriptTypeNote: some View {
    HStack(spacing: 6) {
      Image(systemName: "info.circle")
        .font(.system(size: 12))
      Text("Only BIP-67 P2WSH script type is supported")
        .font(.hbLabel(12))
    }
    .foregroundStyle(Color.hbTextSecondary)
  }

  private var choiceCards: some View {
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
  }

  private var backButton: some View {
    Button(action: { viewModel.goBack() }) {
      Text("Back")
        .font(.hbBody(16))
        .foregroundStyle(Color.hbTextSecondary)
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
      .birchCard()
    }
  }
}

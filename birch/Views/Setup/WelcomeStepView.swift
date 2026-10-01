import SwiftUI

struct WelcomeStepView: View {
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
    VStack(spacing: 32) {
      Spacer()

      appIcon

      titleBlock

      featureList
        .padding(.horizontal, 24)

      // Phone: the action sits at the bottom. Readable column: it stays with
      // the content, and the group centers together.
      if layout == .column {
        Color.clear.frame(height: 24)
      } else {
        Spacer()
      }

      getStartedButton
        .padding(.horizontal, 24)
        .padding(.bottom, 32)

      if layout == .column {
        Spacer()
      }
    }
    .setupReadableWidth()
  }

  /// Left: the brand. Right: what the app does and the way in.
  private var twoColumnBody: some View {
    SetupTwoColumn {
      VStack(spacing: 32) {
        Spacer(minLength: 16)
        appIcon
        titleBlock
        Spacer(minLength: 16)
      }
    } trailing: {
      VStack(alignment: .leading, spacing: 40) {
        Spacer(minLength: 16)
        featureList
        getStartedButton
        Spacer(minLength: 16)
      }
    }
  }

  private var appIcon: some View {
    ThemedAppIcon()
      .aspectRatio(contentMode: .fit)
      .frame(width: 120, height: 120)
      .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .stroke(Color.hbBackground, lineWidth: 24)
          .blur(radius: 12)
          .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
      )
  }

  private var titleBlock: some View {
    VStack(spacing: 12) {
      Text("Birch Wallet")
        .font(.hbDisplay(34))
        .foregroundStyle(Color.hbTextPrimary)

      Text("A Bitcoin Multisig Coordinator")
        .font(.hbBody(17))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  private var featureList: some View {
    VStack(alignment: .leading, spacing: 16) {
      FeatureRow(icon: "eye.fill", text: "Watch-only — no private keys stored")
      FeatureRow(icon: "person.3.fill", text: "Multi-signature security (M-of-N)")
      FeatureRow(icon: "qrcode.viewfinder", text: "Airgapped QR signing device support")
      FeatureRow(icon: "server.rack", text: "Connect to your own Electrum server")
      FeatureRow(icon: "wallet.bifold.fill", text: "Coordinate multiple wallets")
    }
  }

  private var getStartedButton: some View {
    Button(action: { viewModel.goToNext() }) {
      Text("Get Started")
        .hbPrimaryButton()
    }
  }
}

private struct FeatureRow: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 18))
        .foregroundStyle(Color.hbBitcoinOrange)
        .frame(width: 28)

      Text(text)
        .font(.hbBody(15))
        .foregroundStyle(Color.hbTextPrimary)
    }
  }
}

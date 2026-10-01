import SwiftUI

struct MultisigConfigView: View {
  @Bindable var viewModel: SetupWizardViewModel
  @State private var showingMSheet = false
  @State private var showingNSheet = false
  @Environment(\.setupLayout) private var layout

  var body: some View {
    if layout == .twoColumn {
      twoColumnBody
    } else {
      singleColumnBody
    }
  }

  private var singleColumnBody: some View {
    ScrollView {
      VStack(spacing: 28) {
        title
          .padding(.top, 16)

        VStack(spacing: 16) {
          subtitle

          signaturePicker
        }
        .padding(.bottom, 0)

        VStack(spacing: 24) {
          settings
        }
        .padding(.horizontal, 24)

        HStack(spacing: 16) {
          backButton

          Spacer()

          Button(action: { viewModel.goToNext() }) {
            Text("Next")
              .font(.hbHeadline)
              .foregroundStyle(.white)
              .padding(.horizontal, 32)
              .padding(.vertical, 14)
              .background(Color.hbBitcoinOrange)
              .clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
      .padding(.top, layout == .column ? 40 : 0)
      .setupReadableWidth()
    }
    .scrollDismissesKeyboard(.interactively)
  }

  /// Left: the question and the M-of-N answer, with Back at the bottom.
  /// Right: network and server settings, with Next at the bottom.
  private var twoColumnBody: some View {
    SetupTwoColumn {
      VStack(alignment: .leading, spacing: 8) {
        title
        subtitle
        Spacer(minLength: 24)
        signaturePicker
          .frame(maxWidth: .infinity)
        Spacer(minLength: 24)
        backButton
      }
      .padding(.vertical, 16)
    } trailing: {
      VStack(spacing: 16) {
        settings
        Spacer(minLength: 16)
        Button(action: { viewModel.goToNext() }) {
          Text("Next")
            .hbPrimaryButton()
        }
      }
      // Start the settings level with the content under the title.
      .padding(.top, 56)
      .padding(.bottom, 16)
    }
  }

  private var title: some View {
    Text("Multisig Configuration")
      .font(.hbDisplay(28))
      .foregroundStyle(Color.hbTextPrimary)
  }

  private var subtitle: some View {
    Text("How many signatures are required?")
      .font(.hbBody(15))
      .foregroundStyle(Color.hbTextSecondary)
  }

  /// Interactive M-of-N display
  private var signaturePicker: some View {
    HStack(spacing: 12) {
      // M Selector Button
      Button(action: { showingMSheet = true }) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.hbBitcoinOrange.opacity(0.7))
          Text("\(viewModel.requiredSignatures)")
            .font(.hbDisplay(48))
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
      .sheet(isPresented: $showingMSheet) {
        NumberPickerSheet(
          title: "Required Signatures",
          range: 1 ... viewModel.totalCosigners,
          selection: $viewModel.requiredSignatures
        )
      }

      Text("of")
        .font(.hbBody(20))
        .foregroundStyle(Color.hbTextSecondary)

      // N Selector Button
      Button(action: { showingNSheet = true }) {
        HStack(spacing: 4) {
          Text("\(viewModel.totalCosigners)")
            .font(.hbDisplay(48))
            .foregroundStyle(Color.hbTextPrimary)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .sheet(isPresented: $showingNSheet) {
        NumberPickerSheet(
          title: "Total Cosigners",
          range: Constants.minCosigners ... Constants.maxCosigners,
          selection: $viewModel.totalCosigners,
          onChange: { newN in
            if viewModel.requiredSignatures > newN {
              viewModel.requiredSignatures = newN
            }
          }
        )
      }
    }
  }

  @ViewBuilder
  private var settings: some View {
    SetupNetworkPicker(viewModel: viewModel)

    // Electrum server
    ElectrumServerSetupSection(viewModel: viewModel, initiallyExpanded: viewModel.network == .mainnet)

    // Advanced
    WalletAdvancedSetupSection(viewModel: viewModel)
  }

  private var backButton: some View {
    Button(action: { viewModel.goBack() }) {
      Text("Back")
        .font(.hbBody(16))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }
}

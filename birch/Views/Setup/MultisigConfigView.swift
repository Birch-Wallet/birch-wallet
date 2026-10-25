import SwiftUI

struct MultisigConfigView: View {
  @Bindable var viewModel: SetupWizardViewModel
  @State private var showingMSheet = false
  @State private var showingNSheet = false
  /// The cosigner count on the wheel, applied when the sheet closes
  @State private var pickedTotal = 0
  /// A lower count that would drop cosigners with keys entered, waiting for
  /// the user to agree
  @State private var pendingTotal: Int?
  @Environment(\.setupLayout) private var layout

  var body: some View {
    ScrollViewReader { proxy in
      if layout == .twoColumn {
        twoColumnBody(proxy: proxy)
      } else {
        singleColumnBody(proxy: proxy)
      }
    }
    .alert(
      removalTitle,
      isPresented: .init(get: { pendingTotal != nil }, set: {
        if !$0 {
          pendingTotal = nil
        }
      }),
    ) {
      Button("Cancel", role: .cancel) { pendingTotal = nil }
      Button("Remove", role: .destructive) {
        if let pendingTotal {
          applyTotal(pendingTotal)
        }
        pendingTotal = nil
      }
    } message: {
      Text(removalMessage)
    }
  }

  private func singleColumnBody(proxy: ScrollViewProxy) -> some View {
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

          Button(action: { goNext(proxy: proxy) }) {
            Text("Next")
              .hbCompactPrimaryButton()
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
  private func twoColumnBody(proxy: ScrollViewProxy) -> some View {
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
        Button(action: { goNext(proxy: proxy) }) {
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
            .foregroundStyle(Color.hbBrandInk.opacity(0.7))
          Text("\(viewModel.requiredSignatures)")
            .font(.hbDisplay(48))
            .foregroundStyle(Color.hbBrandInk)
        }
      }
      .sheet(isPresented: $showingMSheet) {
        NumberPickerSheet(
          title: "Required Signatures",
          range: 1 ... viewModel.totalCosigners,
          selection: $viewModel.requiredSignatures,
        )
        .birchSheet()
      }

      Text("of")
        .font(.hbBody(20))
        .foregroundStyle(Color.hbTextSecondary)

      // N Selector Button
      Button(action: {
        pickedTotal = viewModel.totalCosigners
        showingNSheet = true
      }) {
        HStack(spacing: 4) {
          Text("\(viewModel.totalCosigners)")
            .font(.hbDisplay(48))
            .foregroundStyle(Color.hbTextPrimary)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
      .sheet(isPresented: $showingNSheet, onDismiss: pickTotal) {
        NumberPickerSheet(
          title: "Total Cosigners",
          range: Constants.minCosigners ... Constants.maxCosigners,
          selection: $pickedTotal,
        )
        .birchSheet()
      }
    }
  }

  @ViewBuilder
  private var settings: some View {
    WalletNameNetworkCard(viewModel: viewModel)

    // Electrum server
    ElectrumServerSetupSection(viewModel: viewModel, initiallyExpanded: viewModel.network == .mainnet)

    // Advanced
    WalletAdvancedSetupSection(viewModel: viewModel)
  }

  private var backButton: some View {
    Button(action: { viewModel.goBack() }) {
      Text("Back")
        .hbCompactSecondaryButton()
    }
  }

  /// Moves on, or scrolls to the flagged Host field and reads out why not
  private func goNext(proxy: ScrollViewProxy) {
    guard !viewModel.goToNext(), let hostError = viewModel.electrumHostError else { return }
    withAnimation {
      proxy.scrollTo(ElectrumServerSetupSection.scrollID, anchor: .top)
    }
    AccessibilityNotification.Announcement(hostError).post()
  }

  /// The wheel closed: lowering the count past cosigners with keys entered asks first
  private func pickTotal() {
    guard pickedTotal != viewModel.totalCosigners, pickedTotal > 0 else { return }
    if viewModel.filledCosignersDropped(byReducingTo: pickedTotal).isEmpty {
      applyTotal(pickedTotal)
    } else {
      pendingTotal = pickedTotal
    }
  }

  private func applyTotal(_ total: Int) {
    viewModel.totalCosigners = total
    if viewModel.requiredSignatures > total {
      viewModel.requiredSignatures = total
    }
    // Drop the removed cosigners now, so raising the count again brings back empty ones
    if !viewModel.cosignerXpubs.isEmpty {
      viewModel.resizeCosigners()
    }
  }

  private var droppedNames: [String] {
    guard let pendingTotal else { return [] }
    return viewModel.filledCosignersDropped(byReducingTo: pendingTotal).map { index in
      let label = viewModel.cosignerLabels[index].trimmingCharacters(in: .whitespaces)
      return label.isEmpty ? "Cosigner \(index + 1)" : label
    }
  }

  private var removalTitle: String {
    droppedNames.count == 1 ? "Remove \(droppedNames[0])?" : "Remove \(droppedNames.count) Cosigners?"
  }

  /// "Cosigner 3 has a key entered. Reduce to 2 cosigners and remove it?"
  private var removalMessage: String {
    guard let pendingTotal else { return "" }
    let names = ListFormatter.localizedString(byJoining: droppedNames)
    let one = droppedNames.count == 1
    return "\(names) \(one ? "has a key" : "have keys") entered. Reduce to \(pendingTotal) "
      + "\(pendingTotal == 1 ? "cosigner" : "cosigners") and remove \(one ? "it" : "them")?"
  }
}

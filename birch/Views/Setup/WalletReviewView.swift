import SwiftUI

struct WalletReviewView: View {
  @Bindable var viewModel: SetupWizardViewModel
  let onComplete: () -> Void
  @State private var showDescriptorPDF = false

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Text("Review Wallet")
          .font(.hbDisplay(28))
          .foregroundStyle(Color.hbTextPrimary)

        // Summary card
        VStack(spacing: 16) {
          ReviewRow(label: "Name", value: viewModel.walletName.isEmpty ? "My Wallet" : viewModel.walletName)
          ReviewRow(label: "Type", value: "\(viewModel.requiredSignatures)-of-\(viewModel.totalCosigners) Multisig")
          ReviewRow(label: "Network", value: viewModel.network.displayName)
          ReviewRow(label: "Script", value: "P2WSH (Native Segwit)")
        }
        .hbCard()
        .padding(.horizontal, 24)

        // Cosigners
        VStack(alignment: .leading, spacing: 12) {
          Text("Cosigners")
            .font(.hbHeadline)
            .foregroundStyle(Color.hbTextPrimary)

          ForEach(0 ..< viewModel.totalCosigners, id: \.self) { index in
            VStack(alignment: .leading, spacing: 6) {
              Text(viewModel.cosignerLabels[index])
                .font(.hbBody(15))
                .foregroundStyle(Color.hbTextPrimary)

              HStack(spacing: 8) {
                Text("FP:")
                  .font(.hbLabel())
                  .foregroundStyle(Color.hbTextSecondary)
                Text(viewModel.cosignerFingerprints[index])
                  .font(.hbMono(12))
                  .foregroundStyle(Color.hbBitcoinOrange)
              }

              Text(viewModel.cosignerXpubs[index])
                .font(.hbMono(10))
                .foregroundStyle(Color.hbTextSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .birchCard(.nested)
          }
        }
        .hbCard()
        .padding(.horizontal, 24)

        // Descriptor PDF
        Button(action: { showDescriptorPDF = true }) {
          HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
            Text("PDF/Print Output Descriptor")
              .font(.hbBody(15))
          }
          .foregroundStyle(Color.purple)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Color.purple.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 24)

        // Create button
        Button(action: onComplete) {
          Text("Create Wallet")
            .hbPrimaryButton()
        }
        .padding(.horizontal, 24)

        Button(action: { viewModel.goBack() }) {
          Text("Back")
            .font(.hbBody(16))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .padding(.bottom, 32)
      }
      .padding(.top, 16)
    }
    .sheet(isPresented: $showDescriptorPDF) {
      DescriptorPDFView(
        walletName: viewModel.walletName.isEmpty ? "My Wallet" : viewModel.walletName,
        descriptor: viewModel.externalDescriptor
      )
      .birchSheet()
    }
  }
}

private struct ReviewRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      Spacer()
      Text(value)
        .font(.hbBody(15))
        .foregroundStyle(Color.hbTextPrimary)
    }
  }
}

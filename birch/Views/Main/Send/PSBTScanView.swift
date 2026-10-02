import SwiftData
import SwiftUI

struct PSBTScanView: View {
  @Bindable var viewModel: SendViewModel
  @Environment(\.modelContext) private var modelContext
  @State private var showManualInput = false
  @State private var showImportFile = false
  @State private var manualPSBTBase64 = ""

  var body: some View {
    VStack(spacing: 24) {
      SendStepIndicator(currentStep: .psbtScan)
        .padding(.horizontal, 24)

      Text("Scan Signed PSBT")
        .font(.hbDisplay(22))
        .foregroundStyle(Color.hbTextPrimary)

      SignatureProgressView(
        collected: viewModel.signaturesCollected,
        required: viewModel.requiredSignatures,
        signerStatus: viewModel.signerStatus
      )

      // QR Scanner
      URScannerSheet(preferMacroCamera: true, expectedTypes: [.psbt]) { result in
        if case let .psbt(data) = result {
          Task { await viewModel.handleSignedPSBT(data, modelContext: modelContext) }
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxHeight: 500)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(.horizontal, 24)

      Button(action: { showImportFile = true }) {
        Label("Import PSBT File", systemImage: "doc.badge.arrow.up")
          .font(.hbBody(14))
          .foregroundStyle(Color.hbBitcoinOrange)
      }

      Button(action: { showManualInput = true }) {
        Label("Paste Base64 PSBT", systemImage: "doc.on.clipboard")
          .font(.hbBody(14))
          .foregroundStyle(Color.hbSteelBlue)
      }

      Spacer()

      Button(action: { viewModel.currentStep = .psbtDisplay }) {
        Text("Back to QR Display")
          .font(.hbBody(16))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .padding(.bottom, 32)
    }
    .padding(.top, 16)
    .alert("Paste Signed PSBT", isPresented: $showManualInput) {
      TextField("Base64 PSBT", text: $manualPSBTBase64)
      Button("Import") {
        if let data = Data(base64Encoded: manualPSBTBase64) {
          Task { await viewModel.handleSignedPSBT(data, modelContext: modelContext) }
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .fileImporter(
      isPresented: $showImportFile,
      allowedContentTypes: [.data, .plainText],
      allowsMultipleSelection: false
    ) { result in
      if case let .success(urls) = result, let url = urls.first {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? Data(contentsOf: url) {
          Task { await viewModel.handleSignedPSBT(data, modelContext: modelContext) }
        }
      }
    }
  }
}

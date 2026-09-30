import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SendFlowView: View {
  @Binding var selectedTab: Int
  @State private var viewModel = SendViewModel()
  @Query private var frozenUTXOs: [FrozenUTXO]
  @Query(sort: \SavedPSBT.updatedAt, order: .reverse) private var allSavedPSBTs: [SavedPSBT]
  @Environment(\.modelContext) private var modelContext
  @State private var bumpFeeViewModel: BumpFeeViewModel?
  @State private var resumeCandidate: SavedPSBT?
  @State private var hasCheckedResume = false
  @State private var resumeDismissed = false
  /// Set by the resume sheet's "Resume signing"; acted on once the sheet has
  /// gone, since an RBF resume presents its own sheet.
  @State private var pendingResume: SavedPSBT?
  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        VStack(spacing: 0) {
          HStack {
            Text("Send")
              .font(.hbAmountLarge)
              .foregroundStyle(Color.hbTextPrimary)

            Spacer()

            if viewModel.currentStep == .recipients {
              Menu {
                Button(action: { viewModel.addRecipient() }) {
                  Label("Add Recipient", systemImage: "plus")
                }
                .disabled(!viewModel.canAddRecipient)
                Button(action: { viewModel.showLoadPSBT = true }) {
                  Label("Saved PSBTs", systemImage: "tray.and.arrow.down")
                }
                Button(action: { viewModel.showImportPSBTQR = true }) {
                  Label("Import PSBT via QR", systemImage: "qrcode.viewfinder")
                }
                Button(action: { viewModel.showImportPSBTFile = true }) {
                  Label("Import PSBT via File", systemImage: "doc")
                }
              } label: {
                Image(systemName: "ellipsis")
                  .font(.system(size: 20))
                  .foregroundStyle(Color.hbTextSecondary)
                  .frame(width: 44, height: 44)
                  .contentShape(Rectangle())
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 4)

          Group {
            switch viewModel.currentStep {
            case .recipients:
              SendRecipientsView(viewModel: viewModel)
            case .review:
              SendReviewView(viewModel: viewModel)
            case .psbtDisplay:
              PSBTDisplayView(viewModel: viewModel)
            case .psbtScan:
              PSBTScanView(viewModel: viewModel)
            case .broadcast:
              BroadcastResultView(viewModel: viewModel, selectedTab: $selectedTab)
            }
          }
        }
      }
      .navigationTitle("")
      .alert("Error", isPresented: .init(
        get: { viewModel.errorMessage != nil },
        set: {
          if !$0 {
            viewModel.errorMessage = nil
          }
        }
      )) {
        Button("OK") { viewModel.errorMessage = nil }
      } message: {
        Text(viewModel.errorMessage ?? "")
      }
    }
    .onAppear {
      loadFrozenOutpoints()
      viewModel.loadBalance()
      checkForResumablePSBT()
    }
    .onChange(of: frozenUTXOs.count) {
      loadFrozenOutpoints()
      viewModel.loadBalance()
    }
    .onChange(of: BitcoinService.shared.currentProfile?.id) {
      viewModel.reset()
      loadFrozenOutpoints()
      viewModel.loadBalance()
      resumeCandidate = nil
      hasCheckedResume = false
      resumeDismissed = false
      pendingResume = nil
      checkForResumablePSBT()
    }
    .sheet(item: $resumeCandidate, onDismiss: handleResumeSheetDismiss) { saved in
      ResumePSBTSheet(savedPSBT: saved) { pendingResume = $0 }
    }
    .sheet(isPresented: $viewModel.showLoadPSBT) {
      SavedPSBTListView(viewModel: viewModel) { savedPSBT in
        bumpFeeViewModel = BumpFeeViewModel(savedPSBT: savedPSBT)
      }
    }
    .sheet(item: $bumpFeeViewModel) { vm in
      BumpFeeView(viewModel: vm)
    }
    .sheet(isPresented: $viewModel.showImportPSBTQR) {
      ImportPSBTQRSheet(viewModel: viewModel)
    }
    .fileImporter(
      isPresented: $viewModel.showImportPSBTFile,
      allowedContentTypes: [.data, .plainText],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case let .success(urls):
        guard let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else {
          viewModel.errorMessage = "Unable to access file"
          return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
          let data = try Data(contentsOf: url)
          viewModel.importPSBT(data, source: "File", context: modelContext)
        } catch {
          viewModel.errorMessage = "Failed to read file: \(error.localizedDescription)"
        }
      case let .failure(error):
        viewModel.errorMessage = "File import failed: \(error.localizedDescription)"
      }
    }
  }

  private func loadFrozenOutpoints() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    viewModel.frozenOutpoints = Set(frozenUTXOs.filter { $0.walletID == walletID }.map(\.outpoint))
  }

  private func checkForResumablePSBT() {
    guard !hasCheckedResume, !resumeDismissed else { return }
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    hasCheckedResume = true

    resumeCandidate = SavedPSBT.resumeCandidate(in: allSavedPSBTs, walletID: walletID)
  }

  /// Every way out of the resume sheet — ✕, swipe, "Start a new transaction" —
  /// means "not now" for this session; only "Resume signing" leaves a pending PSBT.
  private func handleResumeSheetDismiss() {
    resumeDismissed = true
    guard let saved = pendingResume else { return }
    pendingResume = nil
    resumePSBT(saved)
  }

  func resumePSBT(_ saved: SavedPSBT) {
    if saved.originalTxid != nil {
      bumpFeeViewModel = BumpFeeViewModel(savedPSBT: saved)
    } else {
      viewModel.loadSavedPSBT(saved)
    }
  }
}

// MARK: - Import PSBT via QR Sheet

struct ImportPSBTQRSheet: View {
  @Bindable var viewModel: SendViewModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  var body: some View {
    NavigationStack {
      URScannerSheet(preferMacroCamera: true, expectedTypes: [.psbt]) { result in
        switch result {
        case let .psbt(data):
          viewModel.importPSBT(data, source: "QR", context: modelContext)
          dismiss()
        default:
          viewModel.errorMessage = "Scanned QR is not a valid PSBT"
          dismiss()
        }
      }
      .navigationTitle("Import PSBT")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
    }
  }
}

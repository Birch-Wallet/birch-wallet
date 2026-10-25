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
      .overlayPreferenceValue(FiatHintAnchorKey.self) { anchor in
        GeometryReader { proxy in
          if viewModel.showFiatHint, let anchor {
            FiatHintOverlay(pillFrame: proxy[anchor], containerWidth: proxy.size.width) {
              withAnimation(.spring(duration: 0.25, bounce: 0.15)) { viewModel.showFiatHint = false }
            }
          }
        }
        .allowsHitTesting(viewModel.showFiatHint)
      }
      .navigationTitle("")
      .alert("Error", isPresented: .init(
        get: { viewModel.errorMessage != nil },
        set: {
          if !$0 {
            viewModel.errorMessage = nil
          }
        },
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
    .onChange(of: selectedTab) {
      // The tab bar stays live above the callout, so a tap on Settings
      // switches tabs and clears it in one go
      if selectedTab != 1 {
        viewModel.showFiatHint = false
      }
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
        .birchSheet()
    }
    .sheet(isPresented: $viewModel.showImportPSBTQR) {
      ImportPSBTQRSheet(viewModel: viewModel)
        .birchSheet()
    }
    .fileImporter(
      isPresented: $viewModel.showImportPSBTFile,
      allowedContentTypes: [.data, .plainText],
      allowsMultipleSelection: false,
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
    guard !hasCheckedResume, !resumeDismissed, let walletID = BitcoinService.shared.currentProfile?.id else { return }
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

// MARK: - Fiat Hint

/// The unit pill on the recipients step reports its bounds here, so the
/// callout can hang beneath whichever pill is showing: the amount card's with
/// one recipient, the Spendable header's with several.
struct FiatHintAnchorKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? {
    nil
  }

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// Dims the Send tab and points at the unit pill to say fiat entry is off.
/// A tap anywhere but the callout dismisses it.
private struct FiatHintOverlay: View {
  let pillFrame: CGRect
  let containerWidth: CGFloat
  let onDismiss: () -> Void

  private let gutter: CGFloat = 16
  private let arrowSize = CGSize(width: 16, height: 8)

  private var cardWidth: CGFloat {
    min(260, containerWidth - gutter * 2)
  }

  /// Trailing edge lines up with the pill, kept inside the side gutters
  private var cardX: CGFloat {
    min(max(pillFrame.maxX - cardWidth, gutter), containerWidth - gutter - cardWidth)
  }

  /// The arrow's leading edge, relative to the card
  private var arrowX: CGFloat {
    min(max(pillFrame.midX - cardX - arrowSize.width / 2, 12), cardWidth - 12 - arrowSize.width)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.black.opacity(0.35)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityLabel("Dismiss")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onDismiss)
        .transition(.opacity)

      callout
        .offset(x: cardX, y: pillFrame.maxY + 4)
        .transition(.scale(
          scale: 0.9,
          anchor: UnitPoint(x: (arrowX + arrowSize.width / 2) / cardWidth, y: 0),
        ).combined(with: .opacity))
    }
  }

  private var callout: some View {
    VStack(alignment: .leading, spacing: 0) {
      CalloutArrow()
        .fill(Color.hbFloating)
        .frame(width: arrowSize.width, height: arrowSize.height)
        .offset(x: arrowX)

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "info.circle.fill")
          .font(.system(size: 17))
          .foregroundStyle(Color.hbInfo)

        VStack(alignment: .leading, spacing: 4) {
          Text("Fiat is off")
            .font(.hbBody(15).weight(.semibold))
            .foregroundStyle(Color.hbTextPrimary)
          Text("Turn on Show Fiat Price in Settings to enter amounts in your local currency.")
            .font(.hbBody(13))
            .foregroundStyle(Color.hbTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(14)
      .frame(width: cardWidth, alignment: .leading)
      .background(Color.hbFloating, in: .rect(cornerRadius: 12, style: .continuous))
    }
    .compositingGroup()
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAction(.escape, onDismiss)
  }
}

/// An upward-pointing triangle that joins the callout to the pill above it
private struct CalloutArrow: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
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
            .buttonStyle(HBBarButtonStyle(prominent: false))
        }
        .hbHidesGlassBackground()
      }
    }
  }
}

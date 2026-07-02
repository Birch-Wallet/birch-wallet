import Bbqr
import SwiftData
import SwiftUI
import URKit

enum QREncoding: String, CaseIterable { case ur = "UR", bbqr = "BBQR" }

/// Computes the total animated-QR frame count for a PSBT payload at the given
/// display settings, matching what URDisplaySheet / BBQRDisplayView will render.
enum QRFrameCounter {
  static func frames(for bytes: Data, encoding: QREncoding, density: QRDensity) -> Int {
    // URKit's FountainEncoder requires messageLen >= 10 (see URDisplaySheet)
    guard bytes.count >= 10 else { return 0 }
    switch encoding {
    case .ur:
      guard let ur = try? URService.encodePSBT(bytes) else { return 0 }
      return Int(UREncoder(ur, maxFragmentLen: density.urFragmentLen).seqLen)
    case .bbqr:
      let options = SplitOptions(encoding: .zlib, minVersion: .v01, maxVersion: density.bbqrMaxVersion)
      guard let split = try? Split.tryFromData(bytes: bytes, fileType: .psbt, options: options) else { return 0 }
      return split.parts().count
    }
  }
}

enum QRDensity: String, CaseIterable { case low = "Low", medium = "Medium", high = "High", super_ = "Super" }

extension QRDensity {
  var urFragmentLen: Int {
    switch self {
    case .low: 80
    case .medium: 160
    case .high: 250
    case .super_: 350
    }
  }

  var bbqrMaxVersion: Version {
    switch self {
    case .low: .v05 // 37×37 modules
    case .medium: .v09 // 53×53
    case .high: .v13 // 69×69
    case .super_: .v17 // 85×85
    }
  }

  /// Minimum QR display height required for this density level
  var requiredHeight: CGFloat? {
    switch self {
    case .super_: 700
    default: nil
    }
  }

  /// Densities available for a given QR display height
  static func available(forHeight height: CGFloat) -> [QRDensity] {
    allCases.filter { density in
      guard let required = density.requiredHeight else { return true }
      return height >= required
    }
  }
}

struct PSBTDisplayView: View {
  @Bindable var viewModel: SendViewModel
  @Environment(\.modelContext) private var modelContext
  @State private var showAdvanced = false
  @AppStorage(Constants.qrFrameRateKey) private var framesPerSecond: Double = 3.0
  @AppStorage(Constants.qrEncodingKey) private var qrEncodingRaw: String = QREncoding.ur.rawValue
  @AppStorage(Constants.qrDensityKey) private var qrDensityRaw: String = QRDensity.medium.rawValue
  @AppStorage(Constants.psbtCompactKey) private var compactPSBT = true
  @State private var showRestartAlert = false
  @State private var showExitConfirmation = false
  @State private var showBackConfirmation = false
  @State private var showExportFile = false
  @State private var qrDisplayHeight: CGFloat = 700
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  private var fiatService: FiatPriceService {
    FiatPriceService.shared
  }

  private var qrEncoding: QREncoding {
    QREncoding(rawValue: qrEncodingRaw) ?? .ur
  }

  private var qrDensity: QRDensity {
    QRDensity(rawValue: qrDensityRaw) ?? .medium
  }

  /// The stored density clamped to what the current QR display height allows.
  /// A persisted "Super" from a taller context (e.g. iPad send screen) must not
  /// render here over-dense; fall back to the densest available option. The
  /// stored preference is never rewritten — it stays valid for larger contexts.
  private var effectiveDensity: QRDensity {
    let available = QRDensity.available(forHeight: qrDisplayHeight)
    return available.contains(qrDensity) ? qrDensity : (available.last ?? .medium)
  }

  private var displayBytes: Data {
    compactPSBT ? PSBTCompactor.compact(viewModel.psbtBytes) : viewModel.psbtBytes
  }

  private var frameCount: Int {
    QRFrameCounter.frames(for: displayBytes, encoding: qrEncoding, density: effectiveDensity)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        // Signature progress
        SignatureProgressView(
          collected: viewModel.signaturesCollected,
          required: viewModel.requiredSignatures,
          signerStatus: viewModel.signerStatus
        )

        // QR Display — constrained to available height
        if !viewModel.psbtBytes.isEmpty {
          GeometryReader { geo in
            // Re-read inside the closure: GeometryReader defers evaluation to layout
            // time, so psbtBytes may have been cleared since the outer guard ran.
            let bytes = displayBytes
            let maxSide = min(geo.size.width, geo.size.height)
            Group {
              if bytes.isEmpty {
                EmptyView()
              } else if qrEncoding == .ur {
                URDisplaySheet(
                  data: bytes,
                  urType: "crypto-psbt",
                  framesPerSecond: framesPerSecond,
                  maxFragmentLen: effectiveDensity.urFragmentLen
                )
                .id("\(effectiveDensity.urFragmentLen)-\(compactPSBT)")
              } else {
                BBQRDisplayView(
                  data: bytes,
                  fileType: .psbt,
                  framesPerSecond: framesPerSecond,
                  maxVersion: effectiveDensity.bbqrMaxVersion
                )
                .id("\(effectiveDensity.rawValue)-bbqr-\(compactPSBT)")
              }
            }
            .frame(width: maxSide - 10, height: maxSide - 10)
            .padding(5)
            .background(Color.white)
            .shadow(color: Color.hbBitcoinOrange.opacity(0.2), radius: 20)
            .frame(maxWidth: .infinity)
          }
          .aspectRatio(1, contentMode: .fit)
          .frame(maxHeight: 700)
          .background(GeometryReader { geo in
            Color.clear.onAppear { qrDisplayHeight = geo.size.height }
              .onChange(of: geo.size.height) { _, h in qrDisplayHeight = h }
          })
        }

        Text("Scan this QR code with your signing device")
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextSecondary)
          .multilineTextAlignment(.center)

        // Advanced settings
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
          VStack(spacing: 12) {
            // Encoding Type
            HStack {
              Text("QR Encoding")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)
              Spacer()
              Picker("", selection: $qrEncodingRaw) {
                ForEach(QREncoding.allCases, id: \.self) { encoding in
                  Text(encoding.rawValue).tag(encoding.rawValue)
                }
              }
              .pickerStyle(.segmented)
              .frame(width: 160)
            }

            // QR Frame Rate
            HStack {
              Text("QR Frame Rate")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)
              Spacer()
              Text("\(Int(framesPerSecond)) FPS")
                .font(.hbMono(14))
                .foregroundStyle(Color.hbBitcoinOrange)
            }

            Slider(value: $framesPerSecond, in: 1 ... 10, step: 1)
              .tint(Color.hbBitcoinOrange)

            // QR Density
            HStack {
              Text("QR Density")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)
              Spacer()
              Picker("", selection: Binding(
                get: { effectiveDensity.rawValue },
                set: { qrDensityRaw = $0 }
              )) {
                ForEach(QRDensity.available(forHeight: qrDisplayHeight), id: \.self) { density in
                  Text(density.rawValue).tag(density.rawValue)
                }
              }
              .pickerStyle(.segmented)
              .frame(width: QRDensity.available(forHeight: qrDisplayHeight).count > 3 ? 260 : 200)
            }

            // Compact PSBT
            HStack {
              Text("Compact PSBT")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)
              Spacer()
              Toggle("", isOn: $compactPSBT)
                .labelsHidden()
                .tint(Color.hbBitcoinOrange)
                // The iOS 26+ switch draws slightly wider than its layout bounds
                // and gets clipped by the DisclosureGroup; inset to compensate
                .padding(.trailing, 4)
            }

            Text("Strips non_witness_utxo and global xpubs from the PSBT. Compatible with SeedSigner and Krux; some signers require these fields.")
              .font(.hbLabel(10))
              .foregroundStyle(Color.hbTextSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)

            // QR payload stats
            HStack {
              Text("QR Payload")
                .font(.hbLabel())
                .foregroundStyle(Color.hbTextSecondary)
              Spacer()
              Text("\(frameCount) frame\(frameCount == 1 ? "" : "s") / \(displayBytes.count.formatted()) bytes")
                .font(.hbMono(14))
                .foregroundStyle(Color.hbTextPrimary)
            }
          }
          .padding(.top, 8)
        }
        .font(.hbBody(14))
        .foregroundStyle(Color.hbTextSecondary)
        .padding(.horizontal, 24)

        Button(action: {
          if viewModel.needsMoreSignatures {
            viewModel.currentStep = .psbtScan
          } else {
            viewModel.currentStep = .broadcast
          }
        }) {
          Text(viewModel.needsMoreSignatures ? "Scan Signed PSBT" : "Broadcast Transaction")
            .hbPrimaryButton()
        }
        .padding(.horizontal, 24)

        HStack(spacing: 24) {
          Button(action: { showExportFile = true }) {
            Label("Export PSBT File", systemImage: "square.and.arrow.up")
              .font(.hbBody(14))
              .foregroundStyle(Color.hbBitcoinOrange)
          }

          Button(action: {
            if viewModel.savedPSBTId != nil {
              viewModel.savePSBT(name: viewModel.savedPSBTName.isEmpty ? viewModel.defaultPSBTName() : viewModel.savedPSBTName, context: modelContext)
              viewModel.showSavedConfirmation = true
            } else {
              viewModel.savedPSBTName = viewModel.defaultPSBTName()
              viewModel.showSavePSBT = true
            }
          }) {
            Label("Save PSBT", systemImage: "tray.and.arrow.down.fill")
              .font(.hbBody(14))
              .foregroundStyle(Color.hbBitcoinOrange)
          }
        }

        Button(action: {
          UIPasteboard.general.string = viewModel.psbtBase64
        }) {
          Label("Copy Base64", systemImage: "doc.on.doc")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbSteelBlue)
        }

        // Transaction details
        PSBTReviewCard(viewModel: viewModel, fiatEnabled: fiatEnabled, fiatService: fiatService)
          .padding(.horizontal, 24)

        // Flow diagram
        TransactionFlowDiagram(viewModel: viewModel)
          .hbCard()
          .padding(.horizontal, 24)

        Button(action: {
          if viewModel.savedPSBTId != nil {
            showExitConfirmation = true
          } else {
            showBackConfirmation = true
          }
        }) {
          Text(viewModel.savedPSBTId != nil ? "Exit" : "Back")
            .font(.hbBody(16))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .padding(.bottom, 32)
      }
      .padding(.top, 8)
    }
    .onChange(of: qrEncodingRaw) { showRestartAlert = true }
    .onChange(of: qrDensityRaw) { showRestartAlert = true }
    .onChange(of: compactPSBT) { showRestartAlert = true }
    .alert("QR Settings Changed", isPresented: $showRestartAlert) {
      Button("OK") {}
    } message: {
      Text("The signing device will need to restart scanning the animated QR code.")
    }
    .alert("Exit Signing?", isPresented: $showExitConfirmation) {
      Button("Exit", role: .destructive) {
        viewModel.currentStep = .recipients
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          viewModel.reset()
        }
      }
      Button("Continue Signing", role: .cancel) {}
    } message: {
      Text("Your PSBT has been saved. You can continue signing by loading it from the Send screen.")
    }
    .alert("Edit Transaction?", isPresented: $showBackConfirmation) {
      Button("Discard & Edit", role: .destructive) {
        viewModel.psbtBase64 = ""
        viewModel.psbtBytes = Data()
        viewModel.signaturesCollected = 0
        viewModel.currentStep = .recipients
      }
      Button("Continue Signing", role: .cancel) {}
    } message: {
      Text(viewModel.signaturesCollected > 0
        ? "Any collected signatures will be lost. You will need to recreate and re-sign the transaction."
        : "You will need to recreate and re-sign the transaction.")
    }
    .alert("Save PSBT", isPresented: $viewModel.showSavePSBT) {
      TextField("Name", text: $viewModel.savedPSBTName)
      Button("Save") {
        let name = viewModel.savedPSBTName.isEmpty ? viewModel.defaultPSBTName() : viewModel.savedPSBTName
        viewModel.savePSBT(name: name, context: modelContext)
        viewModel.showSavedConfirmation = true
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Enter a name for this PSBT")
    }
    .overlay {
      if viewModel.showSavedConfirmation {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 32))
            .foregroundStyle(Color.hbSuccess)
          Text("PSBT Saved")
            .font(.hbBody(16))
            .foregroundStyle(Color.hbTextPrimary)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .transition(.opacity)
        .onAppear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { viewModel.showSavedConfirmation = false }
          }
        }
      }
    }
    .animation(.easeInOut, value: viewModel.showSavedConfirmation)
    .fileExporter(
      isPresented: $showExportFile,
      document: PSBTFileDocument(data: viewModel.psbtBytes),
      contentType: .data,
      defaultFilename: "transaction.psbt"
    ) { _ in }
  }
}

// MARK: - PSBT Review Card

private struct PSBTReviewCard: View {
  let viewModel: SendViewModel
  let fiatEnabled: Bool
  let fiatService: FiatPriceService

  var body: some View {
    VStack(spacing: 16) {
      ForEach(Array(viewModel.recipients.enumerated()), id: \.element.id) { index, recipient in
        if viewModel.recipients.count > 1 {
          ReviewItem(label: "Recipient \(index + 1)") {
            recipient.address.chunkedAddressText(font: .hbMono(12))
          }
        } else {
          ReviewItem(label: "To") {
            recipient.address.chunkedAddressText(font: .hbMono(12))
          }
        }

        if !recipient.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ReviewItem(label: "Label") {
            HStack(spacing: 4) {
              Image(systemName: "tag.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.hbSteelBlue)
              Text(recipient.label)
                .font(.hbBody())
                .foregroundStyle(Color.hbTextPrimary)
            }
          }
        }

        ReviewItem(label: viewModel.isSelfRecipient(recipient)
          ? "Self Transfer"
          : (viewModel.recipients.count > 1 ? "Amount \(index + 1)" : "Amount"))
        {
          if recipient.isSendMax {
            HStack(spacing: 6) {
              Text("MAX (\(recipient.amountValue?.formattedSats ?? "—"))")
                .font(.hbMonoBold(16))
                .foregroundStyle(Color.hbBitcoinOrange)
              if fiatEnabled, let sats = recipient.amountValue,
                 let fiat = fiatService.formattedSatsToFiat(sats)
              {
                Text(fiat)
                  .font(.hbBody(13))
                  .foregroundStyle(Color.hbTextSecondary)
              }
            }
          } else {
            HStack(spacing: 6) {
              Text(recipient.amountValue?.formattedSats ?? "0 sats")
                .font(.hbMonoBold(16))
                .foregroundStyle(Color.hbBitcoinOrange)
              if fiatEnabled, let sats = recipient.amountValue,
                 let fiat = fiatService.formattedSatsToFiat(sats)
              {
                Text(fiat)
                  .font(.hbBody(13))
                  .foregroundStyle(Color.hbTextSecondary)
              }
            }
          }
        }

        if index < viewModel.recipients.count - 1 {
          Divider()
            .overlay(Color.hbBorder)
        }
      }

      if viewModel.recipients.count > 1 {
        ReviewItem(label: "Total") {
          HStack(spacing: 6) {
            Text(viewModel.totalSendAmount.formattedSats)
              .font(.hbMonoBold(16))
              .foregroundStyle(Color.hbTextPrimary)
            if fiatEnabled, let fiat = fiatService.formattedSatsToFiat(viewModel.totalSendAmount) {
              Text(fiat)
                .font(.hbBody(13))
                .foregroundStyle(Color.hbTextSecondary)
            }
          }
        }
      }

      ReviewItem(label: "Fee Rate") {
        Text("\(viewModel.feeRateSatVb) sat/vB")
          .font(.hbMono())
          .foregroundStyle(Color.hbTextPrimary)
      }

      if viewModel.totalFee > 0 {
        ReviewItem(label: "Total Fee") {
          HStack(spacing: 6) {
            Text(viewModel.totalFee.formattedSats)
              .font(.hbMono())
              .foregroundStyle(Color.hbTextPrimary)
            if fiatEnabled, let fiat = fiatService.formattedSatsToFiat(viewModel.totalFee) {
              Text(fiat)
                .font(.hbBody(13))
                .foregroundStyle(Color.hbTextSecondary)
            }
          }
        }
      }

      if viewModel.inputCount > 0 {
        ReviewItem(label: "Inputs") {
          Text("\(viewModel.inputCount) UTXO\(viewModel.inputCount == 1 ? "" : "s")")
            .font(.hbMono())
            .foregroundStyle(Color.hbTextPrimary)
        }
      }

      ReviewItem(label: "Inputs Amount") {
        Text(viewModel.inputsAmount.formattedSats)
          .font(.hbMonoBold(16))
          .foregroundStyle(Color.hbTextPrimary)
      }

      if let changeAmount = viewModel.changeAmount {
        ReviewItem(label: "Change") {
          Text(changeAmount.formattedSats)
            .font(.hbMono())
            .foregroundStyle(Color.hbTextPrimary)
        }
      }

      ReviewItem(label: "Signatures Required") {
        Text("\(viewModel.requiredSignatures)")
          .font(.hbMono())
          .foregroundStyle(Color.hbTextPrimary)
      }
    }
    .hbCard()
  }
}

// MARK: - Signature Progress

struct SignatureProgressView: View {
  let collected: Int
  let required: Int
  var signerStatus: [(label: String, fingerprint: String, hasSigned: Bool)] = []
  @State private var tappedIndex: Int?

  /// Cosigners who have signed, ordered to fill slots left-to-right
  private var signedCosigners: [(label: String, fingerprint: String)] {
    signerStatus.filter(\.hasSigned).map { (label: $0.label, fingerprint: $0.fingerprint) }
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        ForEach(0 ..< required, id: \.self) { index in
          let signer = index < signedCosigners.count ? signedCosigners[index] : nil
          let isSigned = signer != nil

          RoundedRectangle(cornerRadius: 6)
            .fill(isSigned ? Color.hbBitcoinOrange : Color.hbSurface)
            .frame(width: 48, height: 48)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                  isSigned ? Color.hbBitcoinOrange : Color.hbBorder,
                  lineWidth: isSigned ? 2 : 1
                )
            )
            .overlay {
              if isSigned {
                Image(systemName: "signature")
                  .font(.system(size: 18))
                  .foregroundStyle(.white)
              } else {
                Text("\(index + 1)")
                  .font(.hbMono(14))
                  .foregroundStyle(Color.hbTextSecondary)
              }
            }
            .animation(.easeOut(duration: 0.3), value: collected)
            .onTapGesture {
              if signer != nil {
                tappedIndex = tappedIndex == index ? nil : index
              }
            }
            .popover(isPresented: Binding(
              get: { tappedIndex == index },
              set: { if !$0 { tappedIndex = nil } }
            )) {
              if let signer {
                VStack(alignment: .leading, spacing: 4) {
                  Text(signer.label)
                    .font(.hbBody(14))
                    .foregroundStyle(Color.hbTextPrimary)
                  Text(signer.fingerprint)
                    .font(.hbMono(12))
                    .foregroundStyle(Color.hbTextSecondary)
                }
                .padding(12)
                .presentationCompactAdaptation(.popover)
              }
            }
        }
      }

      Text("\(collected) of \(required) required signatures")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
    }
  }
}

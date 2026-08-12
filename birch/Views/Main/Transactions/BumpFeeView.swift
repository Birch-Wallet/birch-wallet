import Bbqr
import SwiftUI

struct BumpFeeView: View {
  @State var viewModel: BumpFeeViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        switch viewModel.currentStep {
        case .feeInput:
          BumpFeeInputView(viewModel: viewModel)
        case .psbtDisplay:
          BumpFeePSBTDisplayView(viewModel: viewModel)
        case .psbtScan:
          BumpFeePSBTScanView(viewModel: viewModel)
        case .broadcast:
          BumpFeeBroadcastView(viewModel: viewModel, dismiss: dismiss)
        }
      }
      .navigationTitle("Bump Fee")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
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
  }
}

// MARK: - Fee Input

private struct BumpFeeInputView: View {
  @Bindable var viewModel: BumpFeeViewModel
  @Environment(\.modelContext) private var modelContext

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // Original fee info
        VStack(spacing: 12) {
          DetailRow(label: "Original Fee") {
            Text(viewModel.originalFee.formattedSats)
              .font(.hbMono())
              .foregroundStyle(Color.hbTextPrimary)
          }

          if let rate = viewModel.originalFeeRate {
            DetailRow(label: "Original Fee Rate") {
              Text("\(String(format: "%.1f", rate)) sat/vB")
                .font(.hbMono())
                .foregroundStyle(Color.hbTextPrimary)
            }
          }

          DetailRow(label: "Minimum to Bump") {
            Text(formatFeeRate(viewModel.minimumBumpRate) + " sat/vB")
              .font(.hbMono())
              .foregroundStyle(Color.hbBitcoinOrange)
          }
        }
        .hbCard()

        BumpFeeRateCard(viewModel: viewModel)

        Button(action: {
          Task {
            await viewModel.createBumpPSBT()
            if !viewModel.psbtBytes.isEmpty, viewModel.errorMessage == nil {
              viewModel.autoSavePSBT(context: modelContext)
            }
          }
        }) {
          if viewModel.isProcessing {
            ProgressView()
              .tint(.white)
              .frame(maxWidth: .infinity, minHeight: 48)
          } else {
            Text("Create Replacement")
              .hbPrimaryButton()
          }
        }
        .disabled(!viewModel.isValidFeeRate || viewModel.isProcessing)
        .padding(.horizontal, 24)
      }
      .padding(16)
    }
    .background(Color.hbBackground)
    .task {
      await viewModel.fetchFeeRates()
    }
  }
}

private struct BumpFeeRateCard: View {
  @Bindable var viewModel: BumpFeeViewModel
  @State private var showFeeMenu = true

  private var currentRateText: String {
    viewModel.feeRateValue > 0
      ? formatFeeRate(viewModel.feeRateValue) + " sat/vB"
      : "--"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text("New Fee Rate")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Spacer()

        Text(currentRateText)
          .font(.hbMono(14))
          .foregroundStyle(Color.hbTextPrimary)

        HStack(spacing: 4) {
          Text(viewModel.selectedFeePreset.displayName)
            .font(.hbBody(14))
            .foregroundStyle(Color.hbBitcoinOrange)
          Image(systemName: showFeeMenu ? "chevron.down" : "chevron.left")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        withAnimation(.easeInOut(duration: 0.2)) { showFeeMenu.toggle() }
      }

      if showFeeMenu {
        Divider()
          .background(Color.hbBorder)

        VStack(spacing: 10) {
          ForEach(FeePreset.allCases, id: \.self) { preset in
            if preset == .custom {
              customRow
            } else {
              presetRow(preset)
            }
          }
        }
      }

      if !viewModel.isValidFeeRate, !viewModel.newFeeRate.isEmpty {
        Text("Must be higher than \(String(format: "%.1f", viewModel.originalFeeRate ?? 0)) sat/vB")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbError)
      }
    }
    .hbCard()
  }

  private func presetRow(_ preset: FeePreset) -> some View {
    Button(action: {
      viewModel.applyPreset(preset)
      withAnimation(.easeInOut(duration: 0.2)) { showFeeMenu = false }
    }) {
      HStack(spacing: 10) {
        Image(systemName: viewModel.selectedFeePreset == preset ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18))
          .foregroundStyle(viewModel.selectedFeePreset == preset ? Color.hbBitcoinOrange : Color.hbBorder)

        Text(preset.displayName)
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextPrimary)

        Spacer()

        if let rate = preset.rate(from: viewModel.recommendedFees) {
          Text(formatFeeRate(rate) + " sat/vB")
            .font(.hbMono(13))
            .foregroundStyle(Color.hbTextPrimary)
        } else {
          Text("-- sat/vB")
            .font(.hbMono(13))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }
      .frame(minHeight: 44)
    }
    .buttonStyle(.plain)
  }

  private var customRow: some View {
    HStack(spacing: 10) {
      Image(systemName: viewModel.selectedFeePreset == .custom ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 18))
        .foregroundStyle(viewModel.selectedFeePreset == .custom ? Color.hbBitcoinOrange : Color.hbBorder)
        .onTapGesture { viewModel.selectedFeePreset = .custom }

      Text(FeePreset.custom.displayName)
        .font(.hbBody(14))
        .foregroundStyle(Color.hbTextPrimary)
        .onTapGesture { viewModel.selectedFeePreset = .custom }

      Spacer()

      TextField("0.0", text: $viewModel.newFeeRate)
        .font(.hbMono(14))
        .keyboardType(.decimalPad)
        .multilineTextAlignment(.trailing)
        .frame(width: 60)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.hbSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              viewModel.selectedFeePreset == .custom && !viewModel.isValidFeeRate && !viewModel.newFeeRate.isEmpty
                ? Color.hbError.opacity(0.8) : .clear,
              lineWidth: 1.5
            )
        )
        .onChange(of: viewModel.newFeeRate) { _, newValue in
          var filtered = newValue.filter { $0.isNumber || $0 == "." }
          if let dotIdx = filtered.firstIndex(of: ".") {
            let afterDot = filtered[filtered.index(after: dotIdx)...]
            filtered = String(filtered[...dotIdx]) + afterDot.filter { $0 != "." }
          }
          if filtered != newValue {
            viewModel.newFeeRate = filtered
          }
          // Only switch to .custom when the value wasn't set by applyPreset
          if let rate = viewModel.selectedFeePreset.rate(from: viewModel.recommendedFees),
             viewModel.newFeeRate == formatFeeRate(rate)
          {
            // Value matches the selected preset — applyPreset wrote this, leave preset as-is
          } else {
            viewModel.selectedFeePreset = .custom
          }
        }
        .onTapGesture { viewModel.selectedFeePreset = .custom }

      Text("sat/vB")
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .frame(minHeight: 44)
  }
}

// MARK: - PSBT Display

private struct BumpFeePSBTDisplayView: View {
  @Bindable var viewModel: BumpFeeViewModel
  @Environment(\.modelContext) private var modelContext
  @State private var showAdvanced = false
  @State private var showExportFile = false
  @State private var showRestartAlert = false
  @AppStorage(Constants.qrFrameRateKey) private var framesPerSecond: Double = 3.0
  @AppStorage(Constants.qrEncodingKey) private var qrEncodingRaw: String = QREncoding.ur.rawValue
  @AppStorage(Constants.qrDensityKey) private var qrDensityRaw: String = QRDensity.medium.rawValue
  @AppStorage(Constants.psbtCompactKey) private var compactPSBT = true
  @State private var qrDisplayHeight: CGFloat = 700

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
        SignatureProgressView(
          collected: viewModel.signaturesCollected,
          required: viewModel.requiredSignatures,
          signerStatus: viewModel.signerStatus
        )

        if !viewModel.psbtBytes.isEmpty {
          GeometryReader { geo in
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

        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
          VStack(spacing: 12) {
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
        .padding(.bottom, 32)
      }
      .padding(.top, 8)
    }
    .background(Color.hbBackground)
    .onChange(of: qrEncodingRaw) { showRestartAlert = true }
    .onChange(of: qrDensityRaw) { showRestartAlert = true }
    .onChange(of: compactPSBT) { showRestartAlert = true }
    .alert("QR Settings Changed", isPresented: $showRestartAlert) {
      Button("OK") {}
    } message: {
      Text("The signing device will need to restart scanning the animated QR code.")
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

// MARK: - PSBT Scan

private struct BumpFeePSBTScanView: View {
  @Bindable var viewModel: BumpFeeViewModel
  @Environment(\.modelContext) private var modelContext
  @State private var showManualInput = false
  @State private var showImportFile = false
  @State private var manualPSBTBase64 = ""

  var body: some View {
    VStack(spacing: 24) {
      Text("Scan Signed PSBT")
        .font(.hbDisplay(22))
        .foregroundStyle(Color.hbTextPrimary)

      SignatureProgressView(
        collected: viewModel.signaturesCollected,
        required: viewModel.requiredSignatures
      )

      URScannerSheet(preferMacroCamera: true, expectedTypes: [.psbt]) { result in
        if case let .psbt(data) = result {
          Task { await viewModel.handleSignedPSBT(data, modelContext: modelContext) }
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .frame(maxHeight: 500)
      .clipShape(RoundedRectangle(cornerRadius: 12))
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
    .background(Color.hbBackground)
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

// MARK: - Broadcast

private struct BumpFeeBroadcastView: View {
  @Bindable var viewModel: BumpFeeViewModel
  @Environment(\.modelContext) private var modelContext
  let dismiss: DismissAction

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      if viewModel.broadcastTxid.isEmpty {
        // Ready to broadcast
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 56))
          .foregroundStyle(Color.hbBitcoinOrange)

        Text("Ready to Broadcast")
          .font(.hbDisplay(22))
          .foregroundStyle(Color.hbTextPrimary)

        Text("Your replacement transaction is fully signed and ready to broadcast.")
          .font(.hbBody())
          .foregroundStyle(Color.hbTextSecondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)

        Button(action: {
          Task { await viewModel.broadcast(modelContext: modelContext) }
        }) {
          if viewModel.isProcessing {
            ProgressView()
              .tint(.white)
              .frame(maxWidth: .infinity, minHeight: 48)
          } else {
            Text("Broadcast Transaction")
              .hbPrimaryButton()
          }
        }
        .disabled(viewModel.isProcessing)
        .padding(.horizontal, 24)
      } else {
        // Success
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 56))
          .foregroundStyle(Color.hbSuccess)

        Text("Replacement Broadcast!")
          .font(.hbDisplay(22))
          .foregroundStyle(Color.hbTextPrimary)

        VStack(spacing: 8) {
          Text("New Transaction ID")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)

          Text(viewModel.broadcastTxid)
            .font(.hbMono(11))
            .foregroundStyle(Color.hbTextPrimary)
            .textSelection(.enabled)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }

        Button(action: {
          UIPasteboard.general.string = viewModel.broadcastTxid
        }) {
          Label("Copy Transaction ID", systemImage: "doc.on.doc")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbSteelBlue)
        }

        Button(action: { dismiss() }) {
          Text("Done")
            .hbPrimaryButton()
        }
        .padding(.horizontal, 24)
      }

      Spacer()
    }
    .background(Color.hbBackground)
  }
}

// MARK: - Detail Row (local)

private struct DetailRow<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  var body: some View {
    HStack {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      Spacer()
      content
    }
  }
}

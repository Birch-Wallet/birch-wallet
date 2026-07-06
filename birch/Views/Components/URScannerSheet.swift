import AVFoundation
import Bbqr
import Combine
import SwiftUI
import URKit
import URUI

private let logger = AppLog(.qr)

struct URScannerSheet: View {
  let onResult: (AppURResult) -> Void
  let onCancel: (() -> Void)?
  let preferMacroCamera: Bool
  let expectedTypes: Set<ScanExpectedType>

  @StateObject private var videoSession: URVideoSession
  @StateObject private var scanState: URScanState
  @State private var estimatedPercent: Double = 0
  @State private var bbqrJoiner = ContinuousJoiner()
  @State private var bbqrMode = false
  @State private var bbqrPartsTotal: UInt16 = 0
  @State private var bbqrPartsReceived: UInt16 = 0
  @State private var currentZoom: CGFloat = 1.0
  @State private var baseZoom: CGFloat = 1.0
  @State private var errorBannerMessage: String?

  private let codesPublisher: URCodesPublisher

  init(
    preferMacroCamera: Bool = false,
    expectedTypes: Set<ScanExpectedType> = [],
    onCancel: (() -> Void)? = nil,
    onResult: @escaping (AppURResult) -> Void
  ) {
    self.onResult = onResult
    self.onCancel = onCancel
    self.preferMacroCamera = preferMacroCamera
    self.expectedTypes = expectedTypes
    let publisher = URCodesPublisher()
    codesPublisher = publisher
    _videoSession = StateObject(wrappedValue: URVideoSession(codesPublisher: publisher))
    _scanState = StateObject(wrappedValue: URScanState(codesPublisher: publisher))
  }

  var body: some View {
    ZStack {
      Color.hbBackground.ignoresSafeArea()

      VStack(spacing: 16) {
        URVideo(videoSession: videoSession)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(ScannerOverlay())
          .gesture(
            MagnifyGesture()
              .onChanged { value in
                guard let device = videoSession.currentCaptureDevice else { return }
                let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)
                let newZoom = min(max(baseZoom * value.magnification, 1.0), maxZoom)
                try? device.lockForConfiguration()
                device.videoZoomFactor = newZoom
                device.unlockForConfiguration()
                currentZoom = newZoom
              }
              .onEnded { _ in
                baseZoom = currentZoom
              }
          )

        if displayProgress > 0, displayProgress < 1 {
          VStack(spacing: 4) {
            ProgressView(value: displayProgress)
              .tint(Color.hbBitcoinOrange)

            Text("\(Int(displayProgress * 100))% received")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
          }
          .padding(.horizontal, 24)
        }
      }

      // Cancel button — top trailing
      if let onCancel {
        VStack {
          HStack {
            Spacer()
            Button(action: onCancel) {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.hbTextPrimary, Color.hbSurface)
            }
            .padding(16)
          }
          Spacer()
        }
      }

      // Error banner — bottom
      if let errorBannerMessage {
        VStack {
          Spacer()
          Text(errorBannerMessage)
            .font(.hbBody(14))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.hbError.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
    }
    .animation(.easeInOut(duration: 0.25), value: errorBannerMessage)
    .onAppear {
      if preferMacroCamera {
        switchToMacroCameraIfAvailable()
      }
      configureCameraForCloseScanning()
    }
    .onReceive(scanState.resultPublisher) { result in
      errorBannerMessage = nil
      switch result {
      case let .ur(ur):
        handleResult(URService.processUR(ur))
      case let .progress(progress):
        estimatedPercent = progress.estimatedPercentComplete
      case let .other(code):
        if let hdKeyResult = URService.parseTextEncodedXpub(code) {
          handleResult(hdKeyResult)
        } else if let descriptor = URService.extractDescriptorFromJSON(code) {
          handleResult(.descriptor(descriptor))
        } else if code.hasPrefix("B$") {
          handlePossibleBBQR(code)
        } else {
          handleResult(.unknown(code))
        }
      case .reject, .failure:
        if !expectedTypes.isEmpty {
          showErrorBanner("QR code not recognized. Expected \(expectedTypeDescription).")
        }
      }
    }
  }

  // MARK: - Result filtering

  private func handleResult(_ appResult: AppURResult) {
    guard !expectedTypes.isEmpty else {
      onResult(appResult)
      return
    }

    if let type = appResult.expectedType, expectedTypes.contains(type) {
      onResult(appResult)
      return
    }

    showErrorBanner("Expected \(expectedTypeDescription), but scanned \(appResult.displayName).")
  }

  private var expectedTypeDescription: String {
    let names = expectedTypes.map(\.displayName)
    switch names.count {
    case 1: return names[0]
    case 2: return "\(names[0]) or \(names[1])"
    default: return names.dropLast().joined(separator: ", ") + ", or " + (names.last ?? "")
    }
  }

  private func showErrorBanner(_ message: String) {
    errorBannerMessage = message
  }

  // MARK: - Progress

  private var displayProgress: Double {
    if bbqrMode, bbqrPartsTotal > 0 {
      return Double(bbqrPartsReceived) / Double(bbqrPartsTotal)
    }
    return estimatedPercent
  }

  // MARK: - Camera

  private func switchToMacroCameraIfAvailable() {
    let preferredTypes: [AVCaptureDevice.DeviceType] = [
      .builtInTripleCamera,
      .builtInDualWideCamera,
    ]
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: preferredTypes,
      mediaType: .video,
      position: .back
    )
    if let macroDevice = discovery.devices.first {
      videoSession.setCaptureDevice(macroDevice)
      logger.info("Switched to macro-capable camera: \(macroDevice.localizedName)")
    }
  }

  private func configureCameraForCloseScanning() {
    guard let device = videoSession.currentCaptureDevice else { return }
    try? device.lockForConfiguration()

    if device.isFocusModeSupported(.continuousAutoFocus) {
      device.focusMode = .continuousAutoFocus
    }
    if device.isAutoFocusRangeRestrictionSupported {
      device.autoFocusRangeRestriction = .near
    }
    if device.isFocusPointOfInterestSupported {
      device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
    }
    if device.isGeometricDistortionCorrectionSupported {
      device.isGeometricDistortionCorrectionEnabled = true
    }

    device.unlockForConfiguration()
  }

  // MARK: - BBQR

  private func handlePossibleBBQR(_ code: String) {
    do {
      let result = try bbqrJoiner.addPart(part: code)
      switch result {
      case .notStarted:
        break
      case let .inProgress(partsLeft):
        bbqrMode = true
        if bbqrPartsTotal == 0 {
          bbqrPartsTotal = partsLeft + 1
        }
        bbqrPartsReceived = bbqrPartsTotal - partsLeft
      case let .complete(joined):
        let data = joined.data()
        let fileType = joined.fileType()
        bbqrMode = false
        switch fileType {
        case .psbt:
          handleResult(.psbt(data))
        case .transaction:
          handleResult(.unknown("bbqr-transaction"))
        case .json, .cbor, .unicodeText:
          handleResult(.unknown("bbqr-\(fileType)"))
        }
      }
    } catch {
      logger.error("BBQR error processing part: \(error)")
    }
  }
}

struct ScannerOverlay: View {
  var body: some View {
    GeometryReader { geo in
      let size = min(geo.size.width, geo.size.height) * 0.7
      let cornerLength: CGFloat = 24
      let origin = CGPoint(
        x: (geo.size.width - size) / 2,
        y: (geo.size.height - size) / 2
      )

      Path { path in
        // Top-left
        path.move(to: CGPoint(x: origin.x, y: origin.y + cornerLength))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x + cornerLength, y: origin.y))

        // Top-right
        path.move(to: CGPoint(x: origin.x + size - cornerLength, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x + size, y: origin.y))
        path.addLine(to: CGPoint(x: origin.x + size, y: origin.y + cornerLength))

        // Bottom-right
        path.move(to: CGPoint(x: origin.x + size, y: origin.y + size - cornerLength))
        path.addLine(to: CGPoint(x: origin.x + size, y: origin.y + size))
        path.addLine(to: CGPoint(x: origin.x + size - cornerLength, y: origin.y + size))

        // Bottom-left
        path.move(to: CGPoint(x: origin.x + cornerLength, y: origin.y + size))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + size))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + size - cornerLength))
      }
      .stroke(Color.hbBitcoinOrange, lineWidth: 3)
    }
  }
}

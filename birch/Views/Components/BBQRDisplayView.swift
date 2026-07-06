import Bbqr
import CoreImage.CIFilterBuiltins
import SwiftUI

private let logger = AppLog(.qr)

struct BBQRDisplayView: View {
  let data: Data
  let fileType: FileType
  var framesPerSecond: Double
  var maxVersion: Version

  @State private var frames: [String] = []
  @State private var currentIndex = 0
  @State private var timer: Timer?
  @State private var qrImages: [UIImage] = []

  init(data: Data, fileType: FileType = .psbt, framesPerSecond: Double = 4.0, maxVersion: Version = .v19) {
    self.data = data
    self.fileType = fileType
    self.framesPerSecond = framesPerSecond
    self.maxVersion = maxVersion
  }

  var body: some View {
    Group {
      if let image = currentImage {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .aspectRatio(1, contentMode: .fit)
      } else {
        ProgressView()
          .tint(Color.hbBitcoinOrange)
      }
    }
    .onAppear {
      generateFrames()
      startTimer()
    }
    .onDisappear {
      stopTimer()
    }
    .onChange(of: framesPerSecond) {
      stopTimer()
      startTimer()
    }
  }

  private var currentImage: UIImage? {
    guard !qrImages.isEmpty else { return nil }
    return qrImages[currentIndex % qrImages.count]
  }

  private func generateFrames() {
    do {
      let options = SplitOptions(
        encoding: .zlib,
        minVersion: .v01,
        maxVersion: maxVersion
      )
      let split = try Split.tryFromData(
        bytes: data,
        fileType: fileType,
        options: options
      )
      frames = split.parts()
      qrImages = frames.compactMap { generateQRImage(from: $0) }
    } catch {
      logger.error("Failed to split BBQR data: \(error)")
    }
  }

  private func generateQRImage(from string: String) -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "L"

    guard let outputImage = filter.outputImage else { return nil }

    let scale = 10.0
    let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  private func startTimer() {
    guard frames.count > 1 else { return }
    let interval = 1.0 / framesPerSecond
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      currentIndex = (currentIndex + 1) % frames.count
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
}

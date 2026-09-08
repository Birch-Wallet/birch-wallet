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
      // Every frame is rendered once, up front, so advancing the animation later is
      // just an array lookup. Shared CIContext — see QRImageRenderer.
      qrImages = frames.compactMap { QRImageRenderer.image(for: $0, scale: 10) }
    } catch {
      logger.error("Failed to split BBQR data: \(error)")
    }
  }

  private func startTimer() {
    guard frames.count > 1 else { return }
    let interval = 1.0 / framesPerSecond
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      currentIndex = (currentIndex + 1) % frames.count
    }
    // .common mode keeps the code advancing while the user scrolls. A timer left in
    // the default mode is suspended for the whole gesture, so the signing device
    // would sit on a stalled frame.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
}

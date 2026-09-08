import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders QR codes to images.
///
/// The one rule: never build a `CIContext` per image. Constructing one allocates and
/// compiles GPU resources — measured at ~3ms per call on the simulator against ~0.3ms
/// when the context is reused, and worse on device. At animated-QR frame rates that
/// difference is the entire scroll budget, several times a second.
@MainActor
enum QRImageRenderer {
  private static let context = CIContext(options: [.useSoftwareRenderer: false])

  /// - Parameters:
  ///   - scale: pixel size of one QR module. 1 renders at native size and lets
  ///     SwiftUI scale it up with `.interpolation(.none)`, which is what the animated
  ///     displays want; static codes use a larger scale so the bitmap they hand to
  ///     the image pipeline is already crisp.
  ///   - correctionLevel: "L", "M", "Q" or "H".
  static func image(for message: Data, correctionLevel: String = "L", scale: CGFloat = 1) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = message
    filter.correctionLevel = correctionLevel

    guard var output = filter.outputImage else { return nil }
    if scale != 1 {
      output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  static func image(for string: String, correctionLevel: String = "L", scale: CGFloat = 1) -> UIImage? {
    image(for: Data(string.utf8), correctionLevel: correctionLevel, scale: scale)
  }
}

/// One frame of an animated QR. Kept deliberately thin: it renders the payload it is
/// given and nothing else, so the only work per frame is the QR render itself.
struct AnimatedQRFrame: View {
  let payload: Data

  var body: some View {
    if let image = QRImageRenderer.image(for: payload) {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .aspectRatio(contentMode: .fit)
    } else {
      ProgressView()
        .tint(Color.hbBitcoinOrange)
    }
  }
}

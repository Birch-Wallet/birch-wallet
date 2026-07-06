import AVFoundation
import CoreImage.CIFilterBuiltins
import UIKit
import URKit

enum QRVideoExporter {
  private static let logger = AppLog(.qr)

  enum ExportError: Error {
    case qrGenerationFailed
    case writerSetupFailed(String)
    case writingFailed(String)
  }

  static func exportMP4(
    ur: UR,
    fileName: String = "Descriptor",
    maxFragmentLen: Int = 160,
    fps: Double = 4.0,
    loopCount: Int = 3,
    qrSize: Int = 800
  ) async throws -> URL {
    logger.info("Exporting QR MP4 '\(fileName)' from \(ur.type) UR (maxFragmentLen \(maxFragmentLen), \(fps) fps, \(loopCount) loops)")

    // Step 1: Generate UR part strings
    let encoder = UREncoder(ur, maxFragmentLen: maxFragmentLen)
    var partStrings: [String] = []

    if encoder.isSinglePart {
      partStrings.append(encoder.nextPart().uppercased())
    } else {
      let count = encoder.seqLen
      for _ in 0 ..< count {
        partStrings.append(encoder.nextPart().uppercased())
      }
    }

    // Step 2: Generate QR images
    let context = CIContext()
    let qrImages: [UIImage] = try partStrings.map { part in
      guard let image = generateQRImage(from: part, context: context, canvasSize: qrSize) else {
        throw ExportError.qrGenerationFailed
      }
      return image
    }

    // Step 3: Write MP4
    let sanitizedName = fileName.replacingOccurrences(of: "/", with: "_")
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(sanitizedName).mp4")

    try? FileManager.default.removeItem(at: outputURL)

    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
      throw ExportError.writerSetupFailed("Failed to create AVAssetWriter")
    }

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: qrSize,
      AVVideoHeightKey: qrSize,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 2_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: qrSize,
        kCVPixelBufferHeightKey as String: qrSize,
      ]
    )

    writer.add(input)

    guard writer.startWriting() else {
      throw ExportError.writerSetupFailed(writer.error?.localizedDescription ?? "Unknown error")
    }

    writer.startSession(atSourceTime: .zero)

    let timescale: CMTimeScale = 600
    let frameDuration = CMTime(value: CMTimeValue(Double(timescale) / fps), timescale: timescale)
    let totalFrames = qrImages.count * loopCount

    for frameIndex in 0 ..< totalFrames {
      let image = qrImages[frameIndex % qrImages.count]
      let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))

      while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
      }

      guard let pool = adaptor.pixelBufferPool,
            let pixelBuffer = pixelBuffer(from: image, width: qrSize, height: qrSize, pool: pool)
      else {
        throw ExportError.writingFailed("Failed to create pixel buffer for frame \(frameIndex)")
      }

      adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }

    input.markAsFinished()

    await writer.finishWriting()

    if writer.status == .failed {
      throw ExportError.writingFailed(writer.error?.localizedDescription ?? "Unknown error")
    }

    logger.info("QR MP4 export complete: \(partStrings.count) parts -> \(outputURL.lastPathComponent)")
    return outputURL
  }

  // MARK: - Private

  private static func generateQRImage(from string: String, context: CIContext, canvasSize: Int) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "L"

    guard let ciImage = filter.outputImage else { return nil }

    // Scale QR to fit within canvas with padding
    let padding: CGFloat = 40
    let availableSize = CGFloat(canvasSize) - padding * 2
    let scale = availableSize / ciImage.extent.width
    let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

    // Center on white canvas
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasSize, height: canvasSize))
    return renderer.image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

      let qrImage = UIImage(cgImage: cgImage)
      let x = (CGFloat(canvasSize) - scaledImage.extent.width) / 2
      let y = (CGFloat(canvasSize) - scaledImage.extent.height) / 2
      qrImage.draw(in: CGRect(x: x, y: y, width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
  }

  private static func pixelBuffer(from image: UIImage, width: Int, height: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

    guard let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let cgContext = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    guard let cgImage = image.cgImage else { return nil }

    cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    return buffer
  }
}

import CoreImage.CIFilterBuiltins
import UIKit
import URKit

enum DescriptorPDFGenerator {
  private static let logger = AppLog(.export)

  static func generate(walletName: String, descriptor: String) -> Data? {
    guard let ur = try? URService.encodeCryptoOutput(descriptor: descriptor) else {
      logger.error("Descriptor PDF export failed: could not UR-encode descriptor for '\(walletName)'")
      return nil
    }
    let urString = UREncoder.encode(ur)
    logger.info("Generating descriptor PDF for '\(walletName)'")

    let pageWidth: CGFloat = 612
    let pageHeight: CGFloat = 792
    let margin: CGFloat = 36
    let contentWidth = pageWidth - margin * 2
    let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

    let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

    let monoFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    let charWrapStyle = NSMutableParagraphStyle()
    charWrapStyle.lineBreakMode = .byCharWrapping
    let textAttrs: [NSAttributedString.Key: Any] = [
      .font: monoFont,
      .foregroundColor: UIColor.black,
      .paragraphStyle: charWrapStyle,
    ]

    // Pre-measure descriptor text to know total height needed
    let textBounds = (descriptor as NSString).boundingRect(
      with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
      options: .usesLineFragmentOrigin,
      attributes: textAttrs,
      context: nil
    )

    return renderer.pdfData { context in
      context.beginPage()

      var y = margin

      // Title
      let titleFont = UIFont.boldSystemFont(ofSize: 18)
      let titleStr = "Output descriptor for \(walletName)"
      let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: UIColor.black,
      ]
      let titleSize = (titleStr as NSString).boundingRect(
        with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
        options: .usesLineFragmentOrigin,
        attributes: titleAttrs,
        context: nil
      )
      (titleStr as NSString).draw(
        in: CGRect(x: margin, y: y, width: contentWidth, height: titleSize.height),
        withAttributes: titleAttrs
      )
      y += titleSize.height + 10

      // QR Code
      if let qrImage = generateQRImage(from: urString) {
        let qrSize = contentWidth
        let minTextOnFirstPage: CGFloat = 40
        let availableHeight = pageHeight - y - margin - minTextOnFirstPage - 10
        let actualQRSize = min(qrSize, availableHeight)
        let qrX = margin + (contentWidth - actualQRSize) / 2
        qrImage.draw(in: CGRect(x: qrX, y: y, width: actualQRSize, height: actualQRSize))
        y += actualQRSize + 10
      }

      // Descriptor text — draw with pagination
      let totalTextHeight = ceil(textBounds.height)
      let firstPageRemaining = pageHeight - y - margin

      if totalTextHeight <= firstPageRemaining {
        // Fits on the first page
        (descriptor as NSString).draw(
          in: CGRect(x: margin, y: y, width: contentWidth, height: firstPageRemaining),
          withAttributes: textAttrs
        )
      } else {
        // Use NSTextContainer/NSLayoutManager for precise page breaking
        let textStorage = NSTextStorage(string: descriptor, attributes: textAttrs)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        // First page container
        let firstContainer = NSTextContainer(size: CGSize(width: contentWidth, height: firstPageRemaining))
        firstContainer.lineFragmentPadding = 0
        firstContainer.lineBreakMode = .byCharWrapping
        layoutManager.addTextContainer(firstContainer)

        // Add continuation page containers until all text is laid out
        var containers = [firstContainer]
        let fullPageHeight = pageHeight - margin * 2
        for _ in 0 ..< 20 { // safety limit
          let container = NSTextContainer(size: CGSize(width: contentWidth, height: fullPageHeight))
          container.lineFragmentPadding = 0
          container.lineBreakMode = .byCharWrapping
          layoutManager.addTextContainer(container)
          containers.append(container)
        }

        // Force layout
        layoutManager.ensureLayout(for: containers.last!)

        // Draw first page text
        let firstGlyphRange = layoutManager.glyphRange(for: firstContainer)
        if firstGlyphRange.length > 0 {
          layoutManager.drawGlyphs(forGlyphRange: firstGlyphRange, at: CGPoint(x: margin, y: y))
        }

        // Draw continuation pages
        for i in 1 ..< containers.count {
          let glyphRange = layoutManager.glyphRange(for: containers[i])
          guard glyphRange.length > 0 else { break }
          context.beginPage()
          layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: margin, y: margin))
        }
      }
    }
  }

  private static func generateQRImage(from string: String) -> UIImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "L"

    guard let outputImage = filter.outputImage else { return nil }

    let scale: CGFloat = 10
    let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

    return UIImage(cgImage: cgImage)
  }
}

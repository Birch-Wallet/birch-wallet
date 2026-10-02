import PDFKit
import SwiftUI

struct DescriptorPDFView: View {
  let walletName: String
  let descriptor: String
  @Environment(\.dismiss) private var dismiss
  @State private var pdfData: Data?

  var body: some View {
    NavigationStack {
      Group {
        if let data = pdfData {
          PDFKitView(data: data)
        } else {
          VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 36))
              .foregroundStyle(Color.hbError)
            Text("Failed to generate PDF")
              .font(.hbBody())
              .foregroundStyle(Color.hbTextSecondary)
          }
        }
      }
      .background(Color.hbBackground)
      .navigationTitle("Output Descriptor")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .buttonStyle(HBBarButtonStyle(prominent: true))
        }
        .hbHidesGlassBackground()
        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 16) {
            Button(action: printPDF) {
              Image(systemName: "printer")
            }
            .foregroundStyle(Color.hbSteelBlue)

            Button(action: sharePDF) {
              Image(systemName: "square.and.arrow.up")
            }
            .foregroundStyle(Color.hbSteelBlue)
          }
        }
      }
    }
    .onAppear {
      pdfData = DescriptorPDFGenerator.generate(walletName: walletName, descriptor: descriptor)
    }
  }

  private func printPDF() {
    guard let data = pdfData else { return }
    let controller = UIPrintInteractionController.shared
    controller.printingItem = data
    controller.present(animated: true)
  }

  private func sharePDF() {
    guard let data = pdfData else { return }
    // Write to a temp file so the share sheet shows a proper filename
    let fileName = "\(walletName.replacingOccurrences(of: " ", with: "_"))_descriptor.pdf"
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    try? data.write(to: tempURL)

    let activityVC = UIActivityViewController(
      activityItems: [tempURL],
      applicationActivities: nil
    )
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          var topVC = windowScene.windows.first?.rootViewController else { return }
    // Walk to the topmost presented controller
    while let presented = topVC.presentedViewController {
      topVC = presented
    }
    if let popover = activityVC.popoverPresentationController {
      popover.sourceView = topVC.view
      popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: 0, width: 0, height: 0)
    }
    topVC.present(activityVC, animated: true)
  }
}

private struct PDFKitView: UIViewRepresentable {
  let data: Data

  func makeUIView(context _: Context) -> PDFView {
    let pdfView = PDFView()
    pdfView.autoScales = true
    pdfView.document = PDFDocument(data: data)
    return pdfView
  }

  func updateUIView(_: PDFView, context _: Context) {}
}

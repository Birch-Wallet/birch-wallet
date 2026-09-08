import SwiftUI

struct QRCodeView: View {
  let content: String

  var body: some View {
    if let image = QRImageRenderer.image(for: content, correctionLevel: "M", scale: 10) {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "qrcode")
        .font(.system(size: 48))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }
}

import SwiftUI

struct CosignerCardView: View {
  let cosigner: CosignerInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "person.badge.key.fill")
          .foregroundStyle(Color.hbBitcoinOrange)

        Text(cosigner.label)
          .font(.hbBody(15))
          .foregroundStyle(Color.hbTextPrimary)

        Spacer()

        Text("#\(cosigner.orderIndex + 1)")
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Fingerprint")
            .font(.hbLabel(10))
            .foregroundStyle(Color.hbTextSecondary)
          Text(cosigner.fingerprint)
            .font(.hbMono(12))
            .foregroundStyle(Color.hbBitcoinOrange)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("Path")
            .font(.hbLabel(10))
            .foregroundStyle(Color.hbTextSecondary)
          Text(cosigner.derivationPath)
            .font(.hbMono(12))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }

      Text(cosigner.xpub)
        .font(.hbMono(9))
        .foregroundStyle(Color.hbTextSecondary)
        .lineLimit(2)
        .truncationMode(.middle)
    }
    .padding(12)
    .birchCard(.nested)
  }
}

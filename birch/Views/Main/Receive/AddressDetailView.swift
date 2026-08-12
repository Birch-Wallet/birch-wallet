import SwiftData
import SwiftUI

struct AddressDetailView: View {
  let address: String
  let index: UInt32

  @Environment(\.modelContext) private var modelContext
  @State private var copied = false
  @State private var addressLabel: String = ""
  @State private var isEditingLabel = false
  @State private var editedLabel: String = ""

  var body: some View {
    VStack(spacing: 24) {
      Spacer()

      QRCodeView(content: address)
        .frame(width: 240, height: 240)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))

      VStack(spacing: 8) {
        Text("Address #\(index)")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        address.chunkedAddressText()
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
          .textSelection(.enabled)

        Button(action: {
          UIPasteboard.general.string = address
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
          }
        }) {
          Label(copied ? "Copied!" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.hbBody(14))
            .foregroundStyle(copied ? Color.hbSuccess : Color.hbSteelBlue)
        }

        // Address label
        HStack(spacing: 8) {
          if isEditingLabel {
            TextField("Add a label...", text: $editedLabel)
              .font(.hbBody(14))
              .padding(8)
              .background(Color.hbSurfaceElevated)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .foregroundStyle(Color.hbTextPrimary)
              .frame(maxWidth: 220)
              .onSubmit { saveLabel() }

            Button(action: saveLabel) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.hbSuccess)
            }
            Button(action: { isEditingLabel = false }) {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.hbTextSecondary)
            }
          } else {
            Button(action: {
              editedLabel = addressLabel
              isEditingLabel = true
            }) {
              HStack(spacing: 4) {
                Image(systemName: addressLabel.isEmpty ? "tag" : "tag.fill")
                  .font(.system(size: 12))
                Text(addressLabel.isEmpty ? "Add Label" : addressLabel)
                  .font(.hbBody(13))
              }
              .foregroundStyle(addressLabel.isEmpty ? Color.hbTextSecondary : Color.hbSteelBlue)
            }
          }
        }
        .padding(.top, 4)
      }

      Spacer()
    }
    .background(Color.hbBackground)
    .navigationTitle("Address #\(index)")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      loadLabel()
    }
  }

  private func loadLabel() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else {
      addressLabel = ""
      return
    }
    let addr = address
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "addr" && $0.ref == addr
    })
    addressLabel = (try? modelContext.fetch(descriptor))?.first?.label ?? ""
  }

  private func saveLabel() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    var trimmed = editedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.utf8.count > WalletLabel.maxLabelLength {
      trimmed = String(trimmed.utf8.prefix(WalletLabel.maxLabelLength))!
    }
    let addr = address
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "addr" && $0.ref == addr
    })
    let existing = (try? modelContext.fetch(descriptor))?.first

    if trimmed.isEmpty {
      if let existing {
        modelContext.delete(existing)
      }
    } else if let existing {
      existing.label = trimmed
    } else {
      modelContext.insert(WalletLabel(walletID: walletID, type: .addr, ref: addr, label: trimmed))
    }
    try? modelContext.save()
    addressLabel = trimmed
    isEditingLabel = false
  }
}

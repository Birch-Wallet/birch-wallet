import SwiftData
import SwiftUI

struct ReceiveView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var viewModel = ReceiveViewModel()
  @State private var copied = false
  @State private var addressLabel: String = ""
  @State private var isEditingLabel = false
  @State private var editedLabel: String = ""
  @State private var walletID: UUID?

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Text("Receive")
          .font(.hbAmountLarge)
          .foregroundStyle(Color.hbTextPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .padding(.bottom, 4)

        Spacer()

        if !viewModel.currentAddress.isEmpty {
          // QR Code
          QRCodeView(content: viewModel.currentAddress)
            .frame(width: 240, height: 240)
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))

          // Address
          VStack(spacing: 8) {
            Text("Address #\(viewModel.addressIndex)")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)

            viewModel.currentAddress.chunkedAddressText()
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 32)
              .textSelection(.enabled)

            Button(action: {
              UIPasteboard.general.string = viewModel.currentAddress
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
        } else {
          ProgressView()
            .tint(Color.hbBitcoinOrange)
        }

        Spacer()

        Button(action: { viewModel.generateNewAddress() }) {
          Text("Next Address")
            .hbSecondaryButton()
        }
        .padding(.horizontal, 24)

        NavigationLink(destination: AddressListView()) {
          Text("View All Addresses")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbSteelBlue)
        }
        .padding(.bottom, 32)
      }
      .background(Color.hbBackground)
      .navigationTitle("")
    }
    .id(walletID)
    .onAppear {
      walletID = BitcoinService.shared.currentProfile?.id
      if let walletID {
        viewModel.loadAddress(for: walletID)
      }
      loadLabel()
    }
    .onChange(of: viewModel.currentAddress) {
      isEditingLabel = false
      loadLabel()
    }
    .onChange(of: BitcoinService.shared.currentProfile?.id) {
      walletID = BitcoinService.shared.currentProfile?.id
      if let walletID {
        viewModel.loadAddress(for: walletID)
      }
      copied = false
      isEditingLabel = false
      loadLabel()
    }
  }

  private func loadLabel() {
    guard let walletID = BitcoinService.shared.currentProfile?.id,
          !viewModel.currentAddress.isEmpty
    else {
      addressLabel = ""
      return
    }
    let addr = viewModel.currentAddress
    let descriptor = FetchDescriptor<WalletLabel>(predicate: #Predicate {
      $0.walletID == walletID && $0.type == "addr" && $0.ref == addr
    })
    addressLabel = (try? modelContext.fetch(descriptor))?.first?.label ?? ""
  }

  private func saveLabel() {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }
    let trimmed = editedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let addr = viewModel.currentAddress
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

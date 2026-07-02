import SwiftData
import SwiftUI

private let logger = AppLog(.app)

struct MainTabView: View {
  @State private var selectedTab = 0
  @State private var walletID: UUID?

  private static let tabNames = ["Transactions", "Send", "Receive", "UTXOs", "Settings"]

  var body: some View {
    TabView(selection: $selectedTab) {
      Tab("Transactions", systemImage: "list.bullet.rectangle", value: 0) {
        TransactionListView()
      }

      Tab("Send", systemImage: "arrow.up.right", value: 1) {
        SendFlowView(selectedTab: $selectedTab)
      }

      Tab("Receive", systemImage: "arrow.down.left", value: 2) {
        ReceiveView()
      }

      Tab("UTXOs", systemImage: "bitcoinsign.circle", value: 3) {
        NavigationStack {
          UTXOListView()
        }
        .id(walletID)
      }

      Tab("Settings", systemImage: "gearshape.fill", value: 4) {
        SettingsView()
      }
    }
    .tint(Color.hbBitcoinOrange)
    .onChange(of: selectedTab) { _, newTab in
      let name = newTab < Self.tabNames.count ? Self.tabNames[newTab] : "Unknown"
      logger.info("Tab changed to \(name)")
    }
    .onAppear {
      walletID = BitcoinService.shared.currentProfile?.id
    }
    .onChange(of: BitcoinService.shared.currentProfile?.id) {
      walletID = BitcoinService.shared.currentProfile?.id
    }
  }
}

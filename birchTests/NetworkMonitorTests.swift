@testable import birch
import Network
import Testing

struct NetworkMonitorTests {
  private static let wifi = NetworkState(offlineReason: nil, interface: .wifi, isExpensive: false, isConstrained: false)
  private static let cellular = NetworkState(offlineReason: nil, interface: .cellular, isExpensive: true, isConstrained: false)

  private static func offline(_ reason: NetworkState.Reason = .notAvailable) -> NetworkState {
    NetworkState(offlineReason: reason, interface: nil, isExpensive: false, isConstrained: false)
  }

  @Test func `only an unsatisfied path is offline`() {
    #expect(NetworkState.offlineReason(status: .satisfied, reason: .notAvailable) == nil)
    #expect(NetworkState.offlineReason(status: .requiresConnection, reason: .notAvailable) == nil)
    #expect(NetworkState.offlineReason(status: .unsatisfied, reason: .notAvailable) == .notAvailable)
    #expect(NetworkState.offlineReason(status: .unsatisfied, reason: .cellularDenied) == .cellularDenied)
    #expect(NetworkState.offlineReason(status: .unsatisfied, reason: .wifiDenied) == .wifiDenied)
    #expect(NetworkState.offlineReason(status: .unsatisfied, reason: .localNetworkDenied) == .localNetworkDenied)
    #expect(NetworkState.offlineReason(status: .unsatisfied, reason: .vpnInactive) == .vpnInactive)
  }

  @Test func `before the first path the phone counts as online`() {
    #expect(!NetworkState.unknown.isOffline)
    #expect(NetworkState.unknown.logDescription == "not known yet")
  }

  @Test func `each reason says what is off`() {
    #expect(Self.offline(.notAvailable).message == "No internet connection")
    #expect(Self.offline(.cellularDenied).message == "Cellular data is turned off for Birch in Settings")
    #expect(Self.offline(.wifiDenied).message == "Wi-Fi is turned off for Birch in Settings")
    #expect(Self.offline(.localNetworkDenied).message == "Local network access is turned off for Birch in Settings")
    #expect(Self.offline(.vpnInactive).message == "The VPN isn't connected")
    #expect(Self.offline(.other).message == "No internet connection")
  }

  @Test func `the log names the interface and its limits`() {
    #expect(Self.wifi.logDescription == "online over Wi-Fi")
    #expect(Self.cellular.logDescription == "online over cellular (expensive)")
    let lowData = NetworkState(offlineReason: nil, interface: .wifi, isExpensive: false, isConstrained: true)
    #expect(lowData.logDescription == "online over Wi-Fi (Low Data Mode)")
    #expect(Self.offline(.notAvailable).logDescription == "offline (notAvailable)")
  }

  @Test func `only a return from offline counts as back online`() {
    #expect(NetworkState.cameBackOnline(from: Self.offline(), to: Self.wifi))
    #expect(NetworkState.cameBackOnline(from: Self.offline(.cellularDenied), to: Self.cellular))
    // Wi-Fi Assist, a handoff or a VPN: still online the whole time
    #expect(!NetworkState.cameBackOnline(from: Self.wifi, to: Self.cellular))
    #expect(!NetworkState.cameBackOnline(from: Self.cellular, to: Self.wifi))
    #expect(!NetworkState.cameBackOnline(from: Self.wifi, to: Self.wifi))
    #expect(!NetworkState.cameBackOnline(from: Self.wifi, to: Self.offline()))
    #expect(!NetworkState.cameBackOnline(from: Self.offline(), to: Self.offline(.cellularDenied)))
    #expect(!NetworkState.cameBackOnline(from: .unknown, to: Self.wifi))
  }
}

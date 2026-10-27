import Foundation
import Network

/// What the phone's network allows now, from NWPathMonitor. It knows whether there is
/// a route, not whether packets get through: a server that is down, a captive portal
/// or 100% packet loss all read as online, so the Electrum timeouts cover those.
struct NetworkState: Equatable, Sendable {
  /// Why there is no route, from NWPath.UnsatisfiedReason
  enum Reason: Equatable, Sendable {
    /// Airplane mode, no signal, or Wi-Fi and cellular both off
    case notAvailable
    /// Cellular data is turned off for Birch in Settings
    case cellularDenied
    /// Wi-Fi is turned off for Birch in Settings
    case wifiDenied
    /// Local network access is turned off for Birch in Settings
    case localNetworkDenied
    /// A VPN the phone must use isn't connected
    case vpnInactive
    case other
  }

  enum Interface: Equatable, Sendable {
    case wifi
    case cellular
    case wired
    case other
  }

  /// Why there is no route, nil while online
  let offlineReason: Reason?
  /// The interface traffic goes over, nil while offline or before the first path
  let interface: Interface?
  /// Cellular, or Wi-Fi through a phone's hotspot
  let isExpensive: Bool
  /// Low Data Mode
  let isConstrained: Bool

  /// Before NWPathMonitor reports its first path, which counts as online so nothing
  /// waits on it
  static let unknown = NetworkState(offlineReason: nil, interface: nil, isExpensive: false, isConstrained: false)

  var isOffline: Bool {
    offlineReason != nil
  }

  /// What an offline sync, check or broadcast says, and the connection sheet shows
  var message: String {
    switch offlineReason {
    case .cellularDenied: "Cellular data is turned off for Birch in Settings"
    case .wifiDenied: "Wi-Fi is turned off for Birch in Settings"
    case .localNetworkDenied: "Local network access is turned off for Birch in Settings"
    case .vpnInactive: "The VPN isn't connected"
    case .notAvailable, .other, nil: "No internet connection"
    }
  }

  /// The state in the sync log and the debug info
  var logDescription: String {
    if let offlineReason {
      return "offline (\(offlineReason))"
    }
    guard let interface else { return "not known yet" }
    let name = switch interface {
    case .wifi: "Wi-Fi"
    case .cellular: "cellular"
    case .wired: "wired"
    case .other: "another interface"
    }
    let notes = [isExpensive ? "expensive" : nil, isConstrained ? "Low Data Mode" : nil].compactMap(\.self)
    return "online over \(name)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
  }

  /// Only a return from offline counts. A change between Wi-Fi and cellular, Wi-Fi
  /// Assist or a VPN coming up keeps the phone online, so it doesn't.
  static func cameBackOnline(from old: NetworkState, to new: NetworkState) -> Bool {
    old.isOffline && !new.isOffline
  }

  /// Offline only when the path is unsatisfied. One that requires a connection, such
  /// as a VPN on demand, sets itself up when a connection starts, so it counts as online.
  static func offlineReason(status: NWPath.Status, reason: NWPath.UnsatisfiedReason) -> Reason? {
    guard status == .unsatisfied else { return nil }
    return switch reason {
    case .notAvailable: .notAvailable
    case .cellularDenied: .cellularDenied
    case .wifiDenied: .wifiDenied
    case .localNetworkDenied: .localNetworkDenied
    case .vpnInactive: .vpnInactive
    @unknown default: .other
    }
  }
}

extension NetworkState {
  init(path: NWPath) {
    let offlineReason = Self.offlineReason(status: path.status, reason: path.unsatisfiedReason)
    let interface: Interface? = if offlineReason != nil {
      nil
    } else if path.usesInterfaceType(.wifi) {
      .wifi
    } else if path.usesInterfaceType(.cellular) {
      .cellular
    } else if path.usesInterfaceType(.wiredEthernet) {
      .wired
    } else {
      .other
    }
    self.init(
      offlineReason: offlineReason,
      interface: interface,
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained,
    )
  }
}

/// Watches the phone's network, so a sync doesn't try while it's offline and starts
/// again when it comes back
@Observable
@MainActor
final class NetworkMonitor {
  static let shared = NetworkMonitor()

  private(set) var state = NetworkState.unknown
  /// Called after each change, with the state before and after
  @ObservationIgnored var onChange: ((NetworkState, NetworkState) -> Void)?
  @ObservationIgnored private var monitor: NWPathMonitor?

  /// Starts watching. Paths arrive on the main queue, in order.
  func start() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let new = NetworkState(path: path)
      MainActor.assumeIsolated {
        self?.update(new)
      }
    }
    monitor.start(queue: .main)
    self.monitor = monitor
  }

  private func update(_ new: NetworkState) {
    let old = state
    guard new != old else { return }
    state = new
    onChange?(old, new)
  }
}

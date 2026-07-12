import Foundation
import Network

enum ConnectivityState: Equatable, Sendable {
    case unknown
    case online
    case offline
}

protocol ConnectivityMonitoring: Sendable {
    var state: ConnectivityState { get }
}

final class NetworkConnectivityMonitor: ConnectivityMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var currentState: ConnectivityState = .unknown

    var state: ConnectivityState {
        lock.withLock { currentState }
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let state: ConnectivityState = switch path.status {
            case .satisfied: .online
            case .unsatisfied: .offline
            case .requiresConnection: .unknown
            @unknown default: .unknown
            }
            self?.lock.withLock { self?.currentState = state }
        }
        monitor.start(queue: DispatchQueue(label: "ai.dictator.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}

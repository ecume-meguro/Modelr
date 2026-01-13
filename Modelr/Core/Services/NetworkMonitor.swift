import os.log
import Foundation
import Network

/// Monitors network connectivity for setup operations
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: ConnectionType = .unknown

    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown

        var isMetered: Bool {
            self == .cellular
        }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.modelr.networkmonitor")

    private init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.connectionType = self?.determineConnectionType(path) ?? .unknown

                if path.status == .satisfied {
                    print("[NetworkMonitor] Connected via \(self?.connectionType ?? .unknown)")
                } else {
                    print("[NetworkMonitor] Disconnected")
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func stopMonitoring() {
        monitor.cancel()
    }

    private func determineConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        }
        return .unknown
    }

    // MARK: - Checks

    /// Check if network is available (synchronous, quick check)
    static func isNetworkAvailable() -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.modelr.networkcheck")
        var isAvailable = false
        let semaphore = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { path in
            isAvailable = path.status == .satisfied
            semaphore.signal()
            monitor.cancel()
        }

        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 2.0)

        return isAvailable
    }

    /// Check if a specific host is reachable
    static func canReach(host: String, port: UInt16 = 443, timeout: TimeInterval = 5.0) async -> Bool {
        guard let url = URL(string: "https://\(host)") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            print("[NetworkMonitor] Cannot reach \(host): \(error)")
            return false
        }
    }

    /// Check if HuggingFace is reachable
    static func canReachHuggingFace() async -> Bool {
        await canReach(host: "huggingface.co")
    }

    /// Get user-friendly error message for network issues
    static func getNetworkErrorMessage(connectionType: ConnectionType) -> String {
        switch connectionType {
        case .cellular:
            return "You're on a cellular connection. Downloading large models may use significant data. Consider connecting to Wi-Fi."
        case .wifi, .ethernet:
            return "Network connection lost. Please check your internet connection and try again."
        case .unknown:
            return "No network connection detected. Please connect to the internet and try again."
        }
    }
}

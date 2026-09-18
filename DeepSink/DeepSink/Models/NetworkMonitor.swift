//
//  NetworkMonitor.swift
//  DeepSink
//

import Foundation
import Network
import Combine

// Lets queued uploads resume the moment connectivity actually returns
// while the app is in the foreground (FR-6's offline requirement), on
// top of the plain launch/foreground resume SessionProcessor already
// does — small enough to be worth the one extra signal.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    private var started = false

    func start(onReconnect: @escaping () -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied
                if !wasConnected && self.isConnected {
                    onReconnect()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "DeepSink.NetworkMonitor"))
    }
}

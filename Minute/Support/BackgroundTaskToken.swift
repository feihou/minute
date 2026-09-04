import UIKit

/// Keeps the app awake long enough to finish background work (mirroring,
/// summary generation). iOS suspends a backgrounded app within seconds
/// otherwise.
@MainActor
final class BackgroundTaskToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        // The expiration handler is documented to run on the main thread.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                expirationHandler()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

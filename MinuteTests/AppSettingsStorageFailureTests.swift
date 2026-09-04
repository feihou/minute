import Foundation
import Testing
@testable import Minute

/// F68: the persistent container's error was discarded by `try?`, so a
/// migration failure that strands the store at every launch was invisible and
/// undiagnosable. It is recorded here, and Settings is the only place the user
/// can act on it.
struct AppSettingsStorageFailureTests {
    @Test func persistentStoreFailureRoundTripsAndClearsOnASuccessfulLaunch() {
        // UserDefaults persist across runs on the simulator; a message left
        // behind here would make Settings offer a destructive reset in a
        // perfectly healthy app.
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.persistentStoreFailureKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.persistentStoreFailureKey)
            } else {
                defaults.removeObject(forKey: AppSettings.persistentStoreFailureKey)
            }
        }

        AppSettings.persistentStoreFailure = "The model configuration is incompatible with the store."
        #expect(AppSettings.persistentStoreFailure == "The model configuration is incompatible with the store.")

        // Every launch writes the outcome, so a store that opens again has to
        // retire the message rather than leave the reset button on screen.
        AppSettings.persistentStoreFailure = nil
        #expect(AppSettings.persistentStoreFailure == nil)
        #expect(defaults.object(forKey: AppSettings.persistentStoreFailureKey) == nil)
    }
}

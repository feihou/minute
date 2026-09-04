import Foundation
import SwiftData
import Testing
@testable import Minute

/// F68: the persistent container's error was discarded by `try?`, so a
/// migration failure that strands the store at every launch was invisible and
/// undiagnosable. It is recorded here, and Settings is the only place the user
/// can act on it.
///
/// Serialized, and one suite rather than two: every test below writes and then
/// asserts the single `storage.persistentStoreFailure` key, and Swift Testing
/// runs separate suites in parallel — a second suite on this key would let one
/// test's write land between another's `= nil` and its `#expect(… == nil)`,
/// which is the flake `MeetingStoreTests` already records once. `@MainActor`
/// for the SwiftData containers the launch-resolution tests build.
@Suite(.serialized)
@MainActor
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

    /// The launch half of F68, which lived inside `MinuteApp.init` — `@main`
    /// scaffolding no test can drive. Both behaviors below are one assignment
    /// each and both are silent when wrong: a failure that is not recorded is a
    /// store stranded with no explanation and no reset, and a failure that is
    /// not cleared is a destructive reset button offered in a healthy app.
    ///
    /// A context does not keep its container alive; letting one go traps on the
    /// next insert. Held for the process, as the other SwiftData suites do.
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        Self.retainedContainers.append(container)
        return container
    }

    /// The error a lightweight migration that cannot run reports — the case
    /// `KnowledgeFact` documents, and the one that strands a store identically
    /// at every launch.
    private struct StoreUnavailable: LocalizedError {
        var errorDescription: String? { "The model configuration is incompatible with the store." }
    }

    private func withRestoredFailureKey(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.persistentStoreFailureKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.persistentStoreFailureKey)
            } else {
                defaults.removeObject(forKey: AppSettings.persistentStoreFailureKey)
            }
        }
        try body()
    }

    @Test func aHealthyLaunchKeepsThePersistentStoreAndRetiresTheOldMessage() throws {
        try withRestoredFailureKey {
            AppSettings.persistentStoreFailure = "A failure recorded at the previous launch."
            let persistent = try makeContainer()
            var madeInMemory = false

            let resolved = MeetingStore.resolveContainer(
                makePersistent: { persistent },
                makeInMemory: {
                    madeInMemory = true
                    return try makeContainer()
                }
            )
            // What MinuteApp.init does with the answer, and the half that is
            // easiest to lose in a refactor.
            AppSettings.persistentStoreFailure = resolved.failure

            #expect(resolved.container === persistent)
            #expect(!resolved.isEphemeral)
            #expect(resolved.failure == nil)
            // The fallback container is never even built on this path.
            #expect(!madeInMemory)
            // Written on every launch, success included, so a store that
            // recovered stops offering the destructive reset.
            #expect(AppSettings.persistentStoreFailure == nil)
        }
    }

    @Test func aStoreThatWillNotOpenFallsBackToMemoryAndRecordsWhy() throws {
        try withRestoredFailureKey {
            AppSettings.persistentStoreFailure = nil
            let inMemory = try makeContainer()

            let resolved = MeetingStore.resolveContainer(
                makePersistent: { throw StoreUnavailable() },
                makeInMemory: { inMemory }
            )
            AppSettings.persistentStoreFailure = resolved.failure

            #expect(resolved.container === inMemory)
            // Drives the session-only recordings directory and the warning
            // banner the whole app shows.
            #expect(resolved.isEphemeral)
            #expect(resolved.failure == "The model configuration is incompatible with the store.")
            // Recorded, not swallowed: Settings is the only place the user can
            // see this or act on it.
            #expect(AppSettings.persistentStoreFailure == "The model configuration is incompatible with the store.")
        }
    }
}

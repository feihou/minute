import Foundation
import Testing
@testable import Minute

/// Two local-model jobs must never hold two model containers at once: 1-2.3 GB
/// of weights twice over is what gets the app killed on the very devices the
/// catalog's memory floors admit, and a killed app loses both in-memory jobs
/// with no failure recorded anywhere.
@MainActor
struct MLXJobGateTests {
    /// Counts how many jobs are inside the gate at the same moment.
    @MainActor
    final class Tracker {
        var active = 0
        var peak = 0
        var finished = 0
        var waitingReports = 0

        func begin() {
            active += 1
            peak = max(peak, active)
        }

        func end() {
            active -= 1
            finished += 1
        }
    }

    @Test func aSecondJobWaitsForTheFirstAndIsToldWhy() async throws {
        let gate = MLXJobGate()
        let tracker = Tracker()
        // Event-driven, not timed: signals make this deterministic on any
        // host speed (the KnowledgeCatchUpTests pattern).
        let (firstJobStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (firstJobMayFinish, finishContinuation) = AsyncStream.makeStream(of: Void.self)
        let (secondJobWaited, waitedContinuation) = AsyncStream.makeStream(of: Void.self)

        let first = Task {
            // Both closures are labelled arguments, never trailing: one
            // labelled plus one trailing closure in the same call trips
            // SwiftLint's multiple_closures_with_trailing_closure, which CI
            // enforces and this machine can't run.
            try await gate.run(onWaiting: {}, body: {
                tracker.begin()
                startedContinuation.yield(())
                var mayFinish = firstJobMayFinish.makeAsyncIterator()
                _ = await mayFinish.next()
                tracker.end()
            })
        }
        var started = firstJobStarted.makeAsyncIterator()
        _ = await started.next()   // the first job definitely holds the gate

        let second = Task {
            // Finishing the stream on exit keeps a broken gate a failing test
            // rather than a hung one.
            defer { waitedContinuation.finish() }
            try await gate.run(
                onWaiting: {
                    tracker.waitingReports += 1
                    waitedContinuation.yield(())
                },
                body: {
                    tracker.begin()
                    tracker.end()
                }
            )
        }
        var waited = secondJobWaited.makeAsyncIterator()
        _ = await waited.next()   // the second job is queued, not running

        #expect(tracker.finished == 0)
        finishContinuation.yield(())
        try await first.value
        try await second.value

        #expect(tracker.peak == 1)
        #expect(tracker.finished == 2)
        #expect(tracker.waitingReports == 1)
        #expect(MLXJobGate.waitingStatus == "Waiting for another local-model job to finish…")
    }

    @Test func aFailedJobStillOpensTheGate() async throws {
        struct Boom: Error {}
        let gate = MLXJobGate()

        await #expect(throws: Boom.self) {
            try await gate.run(onWaiting: {}, body: { () async throws -> Void in throw Boom() })
        }

        // A wedged gate would hang every later summary forever.
        var ran = false
        try await gate.run(onWaiting: {}, body: { ran = true })
        #expect(ran)
    }
}

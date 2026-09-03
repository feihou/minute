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
        /// Jobs that ended by cancellation rather than by running.
        var stopped = 0
        /// Jobs that ended by throwing something other than cancellation —
        /// separated so a wrong error reads as a wrong error, not as a
        /// cancellation that never arrived.
        var otherFailures = 0

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

    /// Stop has to be felt while a job is still queued. The queue is new — before
    /// the gate every job started at once and unwound inside one generation step
    /// — and a queued job that ignores cancellation sits on screen for the length
    /// of the *other* meeting's generation, minutes of it, with Stop already
    /// tapped. Worse, MeetingJobs clears its per-meeting in-flight slot only when
    /// the task body ends, so until then every later job for that meeting —
    /// a fresh Generate, a re-transcription — is turned away as "already busy".
    ///
    /// The time limit names the failure: a gate that ignores cancellation makes
    /// this a hang, and every wait below is cancellation-responsive so the
    /// verdict is a reported failure rather than a stuck run.
    @Test(.timeLimit(.minutes(1)))
    func aQueuedJobStopsWithoutWaitingForTheRunningOne() async throws {
        let gate = MLXJobGate()
        let tracker = Tracker()
        let (firstJobStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (firstJobMayFinish, finishContinuation) = AsyncStream.makeStream(of: Void.self)
        let (secondJobWaited, waitedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (secondJobEnded, endedContinuation) = AsyncStream.makeStream(of: Void.self)

        let first = Task {
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
            defer { endedContinuation.finish() }
            do {
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
            } catch is CancellationError {
                tracker.stopped += 1
            } catch {
                tracker.otherFailures += 1
            }
        }
        var waited = secondJobWaited.makeAsyncIterator()
        _ = await waited.next()   // the second job is queued, not running

        second.cancel()
        // The first job is still holding the gate on purpose: this wait can only
        // end if cancellation reached the queue itself.
        var ended = secondJobEnded.makeAsyncIterator()
        _ = await ended.next()

        #expect(tracker.stopped == 1)
        #expect(tracker.otherFailures == 0)
        #expect(tracker.finished == 0)   // the running job hasn't finished yet
        #expect(tracker.peak == 1)       // the stopped job never ran its body

        // A job that never took the gate must not have released it either: the
        // first job still owns it, and the next job gets it when that one ends.
        finishContinuation.yield(())
        try await first.value
        #expect(tracker.finished == 1)

        var thirdRan = false
        try await gate.run(onWaiting: {}, body: { thirdRan = true })
        #expect(thirdRan)
    }

    /// A job stopped before its turn came must not start a multi-minute
    /// generation the moment the gate opens.
    @Test(.timeLimit(.minutes(1)))
    func anAlreadyStoppedJobNeverEntersTheGate() async throws {
        let gate = MLXJobGate()
        let tracker = Tracker()
        let (jobMayStart, startContinuation) = AsyncStream.makeStream(of: Void.self)
        let (jobEnded, endedContinuation) = AsyncStream.makeStream(of: Void.self)

        let job = Task {
            defer { endedContinuation.finish() }
            // Cancellation lands while the job is parked here — AsyncStream's
            // iterator finishes on cancel — so run() is entered with the flag
            // already set, no second job needed to hold the gate.
            var mayStart = jobMayStart.makeAsyncIterator()
            _ = await mayStart.next()
            do {
                try await gate.run(
                    onWaiting: { tracker.waitingReports += 1 },
                    body: {
                        tracker.begin()
                        tracker.end()
                    }
                )
            } catch is CancellationError {
                tracker.stopped += 1
            } catch {
                tracker.otherFailures += 1
            }
        }
        job.cancel()
        startContinuation.yield(())

        var ended = jobEnded.makeAsyncIterator()
        _ = await ended.next()

        #expect(tracker.stopped == 1)
        #expect(tracker.finished == 0)
        // Nothing was queued behind anything, so there was no wait to explain.
        #expect(tracker.waitingReports == 0)

        // And the gate is free, not left half-taken by the job that bailed out.
        var laterRan = false
        try await gate.run(onWaiting: {}, body: { laterRan = true })
        #expect(laterRan)
    }

    /// A job that walks straight in is never told it is waiting: the status text
    /// exists to explain a queue, and showing it with no queue would misreport
    /// an ordinary summary as blocked.
    @Test func aJobThatNeverQueuesIsNeverToldToWait() async throws {
        let gate = MLXJobGate()
        let tracker = Tracker()

        var ran = false
        try await gate.run(onWaiting: { tracker.waitingReports += 1 }, body: { ran = true })

        #expect(ran)
        #expect(tracker.waitingReports == 0)
    }
}

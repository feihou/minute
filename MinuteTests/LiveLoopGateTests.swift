import Foundation
import Testing
@testable import Minute

/// The latch `WhisperTranscriptionService.finish()` waits on instead of the
/// live loop's own Task. Everything here waits on a signal a working gate
/// sends, so a gate that never lets go turns these into hangs — which is
/// exactly the symptom on the recording screen the gate exists to prevent, and
/// the time limits make it a reported failure rather than a stuck suite.
@MainActor
struct LiveLoopGateTests {
    /// Records what happened in what order, so "the waiter did not get past a
    /// closed gate" is an ordering fact rather than a timing one. A class
    /// rather than a local `var`: a `Task` closure is `@Sendable` and may not
    /// capture a mutable local.
    @MainActor
    final class Log {
        private(set) var events: [String] = []

        func record(_ event: String) { events.append(event) }
    }

    @Test(.timeLimit(.minutes(1)))
    func waitSuspendsUntilTheGateOpens() async {
        let gate = LiveLoopGate()
        let log = Log()
        // Event-driven, not timed: signals make this deterministic on any host
        // speed (the MLXJobGateTests pattern).
        let (waiterStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let waiter = Task {
            startedContinuation.yield(())
            await gate.wait()
            log.record("returned")
        }
        var started = waiterStarted.makeAsyncIterator()
        _ = await started.next()   // the waiter is definitely at the gate
        #expect(!gate.isOpen)

        // Order, not elapsed time: a `wait()` that fell straight through would
        // have run the waiter to completion while this body was still
        // suspended on the handshake above, putting "returned" first.
        log.record("opened")
        gate.open()
        await waiter.value

        #expect(log.events == ["opened", "returned"])
        #expect(gate.isOpen)
    }

    /// `finish()` can arrive after `cancel()` has already opened the gate —
    /// a waiter that only ever resumes from an `open()` it was present for
    /// would hang there forever.
    @Test(.timeLimit(.minutes(1)))
    func waitAfterOpenReturnsImmediately() async {
        let gate = LiveLoopGate()
        gate.open()

        await gate.wait()

        #expect(gate.isOpen)
    }

    @Test(.timeLimit(.minutes(1)))
    func everyWaiterResumes() async {
        let gate = LiveLoopGate()
        let log = Log()
        let (waitersStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let waiters = ["first", "second"].map { name in
            Task {
                startedContinuation.yield(())
                await gate.wait()
                log.record(name)
            }
        }
        var started = waitersStarted.makeAsyncIterator()
        _ = await started.next()
        _ = await started.next()

        gate.open()
        for waiter in waiters {
            await waiter.value
        }

        #expect(log.events.sorted() == ["first", "second"])
    }

    /// `cancel()` opens the gate and the loop opens it again on its way out,
    /// in either order — and resuming one continuation twice traps the
    /// process rather than failing an expectation.
    @Test(.timeLimit(.minutes(1)))
    func aSecondOpenIsANoOp() async {
        let gate = LiveLoopGate()
        let log = Log()
        let (waiterStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let waiter = Task {
            startedContinuation.yield(())
            await gate.wait()
            log.record("returned")
        }
        var started = waiterStarted.makeAsyncIterator()
        _ = await started.next()

        gate.open()
        gate.open()
        await waiter.value

        #expect(log.events == ["returned"])
        #expect(gate.isOpen)
    }
}

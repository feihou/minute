import AVFoundation
import os
import Testing
@testable import Minute

struct BufferHandlerBoxTests {
    /// One buffer of `seconds` of audio, marked in its first sample so the
    /// test can identify it after the box has copied it.
    private func buffer(marker: Float, seconds: Double = 0.1, sampleRate: Double = 8_000) -> AVAudioPCMBuffer {
        Self.makeBuffer(marker: marker, seconds: seconds, sampleRate: sampleRate)
    }

    /// Static so the re-entrancy test below can build a buffer from inside a
    /// `@Sendable` handler without capturing the test struct.
    private static func makeBuffer(marker: Float, seconds: Double = 0.1, sampleRate: Double = 8_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0][0] = marker
        return buffer
    }

    @Test func clearingHandlerAfterManyBufferDeliveriesDoesNotOverflowTheStack() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        let box = BufferHandlerBox()
        let deliveryCount = OSAllocatedUnfairLock(initialState: 0)
        box.install { _ in
            deliveryCount.withLock { $0 += 1 }
        }

        // A long recording reads this handler thousands of times. The old
        // lock-backed closure value accumulated a reabstraction wrapper on
        // every read, then recursively released the entire chain on stop.
        for _ in 0..<20_000 {
            box.offer(buffer)
        }

        #expect(deliveryCount.withLock { $0 } == 20_000)
        box.install(nil)
        box.offer(buffer)
        #expect(deliveryCount.withLock { $0 } == 20_000)
    }

    /// Buffers captured before the transcription engine attaches — a second or
    /// two of prepare() + start(), minutes on a first run — used to be dropped
    /// on the floor, so every transcript began mid-sentence.
    @Test func buffersOfferedBeforeAHandlerAttachesAreReplayedInOrderFirst() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.offer(buffer(marker: 2))
        box.offer(buffer(marker: 3))

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }
        box.offer(buffer(marker: 4))

        #expect(received.withLock { $0 } == [1, 2, 3, 4])
    }

    @Test func theBacklogHoldsAtMostThirtySecondsOfAudioAndReportsHowMuch() {
        let box = BufferHandlerBox()
        // 35 one-second buffers: the oldest five fall off the front.
        for marker in 1...35 {
            box.offer(buffer(marker: Float(marker), seconds: 1))
        }

        // The session reads this to place the analyzer's clock origin at the
        // START of the lead-in it is about to be handed. It has to be read
        // before installing, because installing drains the queue.
        #expect(BufferHandlerBox.backlogLimit == 30)
        #expect(box.backlogSeconds == 30)

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }

        #expect(received.withLock { $0 } == (6...35).map(Float.init))
        #expect(box.backlogSeconds == 0)
    }

    @Test func clearingTheHandlerDropsTheBacklogInsteadOfReplayingItLater() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.install(nil) // What stop() does.

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }
        box.offer(buffer(marker: 2))

        #expect(received.withLock { $0 } == [2])
    }

    /// `install` latches collecting off for the rest of a recording, so a box
    /// reused across a stop/start cycle would silently drop the next
    /// recording's lead-in. `AudioRecorder.start(writingTo:quality:)` re-arms
    /// it; keep that contract inside the box rather than in the one caller.
    @Test func resettingReArmsTheBoxForTheNextRecording() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.install(nil) // Previous recording: no engine attached.

        box.reset() // What start() does for the next recording.
        box.offer(buffer(marker: 2))
        let received = OSAllocatedUnfairLock(initialState: [Float]())
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
        }

        // The new recording's lead-in is held and replayed; the old
        // recording's buffer is gone.
        #expect(received.withLock { $0 } == [2])
    }

    /// The interlock that makes the ordering claim in the box's doc comment
    /// true. A live buffer arriving *during* the replay has to queue behind the
    /// rest of the lead-in: `install` sets `isDraining`, and while it is set
    /// `offer` enqueues instead of delivering. Every other test here is
    /// single-threaded with the drain already finished before the next offer,
    /// so deleting `isDraining` leaves them green. Re-entering `offer` from
    /// inside the handler is the tap thread delivering mid-replay, without a
    /// second thread to make it flaky: without the interlock the fourth buffer
    /// is delivered nested inside the first delivery, i.e. [1, 4, 2, 3].
    @Test func aBufferOfferedDuringTheReplayQueuesBehindTheRestOfTheLeadIn() {
        let box = BufferHandlerBox()
        box.offer(buffer(marker: 1))
        box.offer(buffer(marker: 2))
        box.offer(buffer(marker: 3))

        let received = OSAllocatedUnfairLock(initialState: [Float]())
        let liveBufferOffered = OSAllocatedUnfairLock(initialState: false)
        box.install { buffer in
            received.withLock { $0.append(buffer.floatChannelData![0][0]) }
            let isFirstDelivery = liveBufferOffered.withLock { offered -> Bool in
                guard !offered else { return false }
                offered = true
                return true
            }
            if isFirstDelivery {
                box.offer(Self.makeBuffer(marker: 4))
            }
        }

        #expect(received.withLock { $0 } == [1, 2, 3, 4])
        // Drop the handler so the box no longer holds a closure that holds it.
        box.install(nil)
    }
}

import AVFoundation
import os
import Testing
@testable import Minute

struct BufferHandlerBoxTests {
    @Test func clearingHandlerAfterManyBufferDeliveriesDoesNotOverflowTheStack() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        let box = BufferHandlerBox()
        let deliveryCount = OSAllocatedUnfairLock(initialState: 0)
        box.handler = { _ in
            deliveryCount.withLock { $0 += 1 }
        }

        // A long recording reads this handler thousands of times. The old
        // lock-backed closure value accumulated a reabstraction wrapper on
        // every read, then recursively released the entire chain on stop.
        for _ in 0..<20_000 {
            box.handler?(buffer)
        }

        #expect(deliveryCount.withLock { $0 } == 20_000)
        box.handler = nil
        #expect(box.handler == nil)
    }
}

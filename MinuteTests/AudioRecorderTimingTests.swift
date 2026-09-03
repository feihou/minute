import AVFoundation
import Foundation
import Testing
@testable import Minute

/// Recorded time is derived from the frames actually written to the file, not
/// from Date() deltas: Date() is not monotonic, so an NTP or carrier time
/// correction mid-meeting (common right after a flight, a call, or a reboot)
/// used to move the saved duration — and every transcript timestamp derived
/// from it — by the size of the correction.
@MainActor
struct AudioRecorderTimingTests {
    @Test func framesConvertToSecondsAtTheFilesSampleRate() {
        #expect(AudioRecorder.seconds(frames: 48_000, sampleRate: 48_000) == 1)
        #expect(AudioRecorder.seconds(frames: 24_000, sampleRate: 48_000) == 0.5)
        #expect(AudioRecorder.seconds(frames: 16_000, sampleRate: 16_000) == 1)
    }

    @Test func anUnknownSampleRateReadsAsNoRecordedTime() {
        // stop() converts with the rate stored when the file was opened; before
        // any file exists that rate is 0, and dividing by it would hand
        // SwiftData an infinite (or NaN) meeting duration.
        #expect(AudioRecorder.seconds(frames: 48_000, sampleRate: 0) == 0)
        #expect(AudioRecorder.seconds(frames: 0, sampleRate: 48_000) == 0)
    }

    @Test func aRecorderThatNeverStartedReportsNoRecordedTime() {
        let recorder = AudioRecorder()
        #expect(recorder.elapsed == 0)
        #expect(recorder.stop() == 0)
    }
}

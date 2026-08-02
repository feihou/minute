import AVFoundation
import OSLog

/// Converts PCM buffers between formats (used for the recording file after a
/// route change, and for the speech analyzer's preferred format).
/// Only ever used serially on the audio tap thread.
/// ponytail: @unchecked Sendable because AVAudioConverter isn't Sendable; safe
/// while the single tap thread is the only caller.
final class AudioBufferConverter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.minuteapp.Minute", category: "AudioBufferConverter")

    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        outputFormat = output
        if input == output {
            converter = nil
        } else if let converter = AVAudioConverter(from: input, to: output) {
            self.converter = converter
        } else {
            return nil
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            Self.logger.error("Buffer conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        return output
    }
}

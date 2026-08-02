import AVFoundation
import Foundation

/// User-tunable recording preferences, stored in UserDefaults. Views bind with
/// @AppStorage using these keys; non-view code reads the static accessors.
enum AppSettings {
    static let audioQualityKey = "recording.audioQuality"
    static let liveTranscriptionKey = "recording.liveTranscription"
    static let autoSummarizeKey = "recording.autoSummarize"
    static let summaryTemplateKey = "summary.template"
    static let summaryContextKey = "summary.context"

    /// Encoder quality applied to new recordings.
    static var audioQuality: AudioQuality {
        AudioQuality(rawValue: UserDefaults.standard.string(forKey: audioQualityKey) ?? "") ?? .high
    }

    /// Whether new recordings run live on-device transcription. Defaults on.
    static var liveTranscriptionEnabled: Bool {
        UserDefaults.standard.object(forKey: liveTranscriptionKey) as? Bool ?? true
    }

    /// Whether a summary is generated automatically after a recording is saved.
    static var autoSummarizeEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoSummarizeKey)
    }

    /// The notes template used when generating summaries.
    static var summaryTemplate: SummaryTemplate {
        SummaryTemplate.template(for: UserDefaults.standard.string(forKey: summaryTemplateKey) ?? SummaryTemplate.standard.id)
    }

    /// Optional user-provided background (attendee names, projects, terms)
    /// injected into summary generation so the model spells them correctly.
    static var summaryContext: String {
        UserDefaults.standard.string(forKey: summaryContextKey) ?? ""
    }
}

/// AAC encoder quality for new recordings. The sample rate always follows the
/// microphone hardware; this only trades encoder effort and file size.
enum AudioQuality: String, CaseIterable, Identifiable {
    case high
    case standard
    case compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: "High"
        case .standard: "Standard"
        case .compact: "Space Saver"
        }
    }

    var detail: String {
        switch self {
        case .high: "Best fidelity, larger files"
        case .standard: "Balanced quality and size"
        case .compact: "Smallest files, lower fidelity"
        }
    }

    var encoderQuality: AVAudioQuality {
        switch self {
        case .high: .max
        case .standard: .medium
        case .compact: .min
        }
    }
}

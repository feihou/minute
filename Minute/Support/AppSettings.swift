import AVFoundation
import Foundation

/// User-tunable recording preferences, stored in UserDefaults. Views bind with
/// @AppStorage using these keys; non-view code reads the static accessors.
enum AppSettings {
    static let audioQualityKey = "recording.audioQuality"
    static let liveTranscriptionKey = "recording.liveTranscription"
    static let transcriptionEngineKey = "transcription.engine"
    static let whisperModelKey = "transcription.whisperModel"
    static let autoSummarizeKey = "recording.autoSummarize"
    static let summaryTemplateKey = "summary.template"
    static let summaryContextKey = "summary.context"
    static let summaryLanguageKey = "summary.language"
    static let iCloudBackupKey = "backup.iCloud"
    static let iCloudDriveKey = "backup.iCloudDrive"
    /// Set when turning the iCloud Drive toggle on couldn't reach the
    /// container. Persisted rather than held in view state so dismissing
    /// Settings before the (slow) first container lookup returns doesn't throw
    /// the explanation away and leave the toggle silently back off.
    static let iCloudDriveUnavailableKey = "backup.iCloudDriveUnavailable"
    /// Set when a background mirror failed and cleared when one succeeds. The
    /// mirror self-heals, but without this a permanently broken backup (signed
    /// out of iCloud, say) looks identical to a working one.
    static let iCloudDriveLastSyncFailedKey = "backup.iCloudDriveLastSyncFailed"

    /// Whether meeting data (audio, transcripts, summaries) is included in the
    /// iPhone's iCloud/computer device backup. Off by default — private by
    /// default, and nothing leaves the device unless the user opts in.
    static var iCloudBackupEnabled: Bool {
        UserDefaults.standard.bool(forKey: iCloudBackupKey)
    }

    /// Whether meetings are mirrored to a browsable "Minute" folder in
    /// iCloud Drive (one folder per meeting: notes + audio). Off by default.
    static var iCloudDriveBackupEnabled: Bool {
        UserDefaults.standard.bool(forKey: iCloudDriveKey)
    }

    /// Whether the most recent background mirror failed. Written by the
    /// mirror, read by Settings.
    static var iCloudDriveLastSyncFailed: Bool {
        get { UserDefaults.standard.bool(forKey: iCloudDriveLastSyncFailedKey) }
        set { UserDefaults.standard.set(newValue, forKey: iCloudDriveLastSyncFailedKey) }
    }

    /// Encoder quality applied to new recordings.
    static var audioQuality: AudioQuality {
        AudioQuality(rawValue: UserDefaults.standard.string(forKey: audioQualityKey) ?? "") ?? .high
    }

    /// Whether new recordings run live on-device transcription. Defaults on.
    static var liveTranscriptionEnabled: Bool {
        UserDefaults.standard.object(forKey: liveTranscriptionKey) as? Bool ?? true
    }

    /// The engine that transcribes meetings. Apple Speech is the default;
    /// Whisper is opt-in and needs a model downloaded in Settings first.
    static var transcriptionEngine: TranscriptionEngineChoice {
        TranscriptionEngineChoice(rawValue: UserDefaults.standard.string(forKey: transcriptionEngineKey) ?? "") ?? .appleSpeech
    }

    /// The Whisper model variant selected in Settings.
    static var whisperModel: String {
        let value = UserDefaults.standard.string(forKey: whisperModelKey) ?? ""
        return value.isEmpty ? WhisperModelCatalog.defaultModel.variant : value
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

    /// English name of the language summaries are written in; nil means
    /// "match the meeting's language". English names because the model
    /// follows "in Spanish" far more reliably than a code like "es".
    static var summaryLanguage: String? {
        let value = UserDefaults.standard.string(forKey: summaryLanguageKey) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Languages offered by the picker — the on-device model's supported set.
    static let summaryLanguageOptions = [
        "English", "Spanish", "French", "German", "Italian",
        "Portuguese", "Japanese", "Korean", "Chinese",
    ]
}

/// Which speech model transcribes meetings.
enum TranscriptionEngineChoice: String, CaseIterable, Identifiable {
    case appleSpeech = "apple"
    case whisper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisper: "Whisper"
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech: "Built into iOS. Transcribes live while you record, in this iPhone's language."
        case .whisper: "Open model by OpenAI. Transcribes after you save and auto-detects the spoken language."
        }
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

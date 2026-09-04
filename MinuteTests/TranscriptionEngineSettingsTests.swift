import Foundation
import Testing
@testable import Minute

/// The engine choice and Whisper model catalog back the Settings picker and
/// the TranscriptionEngines factory — a bad default or a renamed variant
/// would silently break transcription for everyone who opted in.
///
/// Serialized: these tests mutate the same shared UserDefaults keys, so
/// running them in parallel races the set/remove against each other.
@Suite(.serialized)
struct TranscriptionEngineSettingsTests {
    /// Runs `body` with the given UserDefaults value, restoring the previous
    /// value afterwards so tests never leak state into each other.
    private func withDefault(_ key: String, set value: String?, _ body: () -> Void) {
        let previous = UserDefaults.standard.string(forKey: key)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test("Apple Speech is the default engine")
    func defaultsToAppleSpeech() {
        withDefault(AppSettings.transcriptionEngineKey, set: nil) {
            #expect(AppSettings.transcriptionEngine == .appleSpeech)
        }
    }

    @Test("A stored Whisper choice is read back")
    func readsWhisperChoice() {
        withDefault(AppSettings.transcriptionEngineKey, set: "whisper") {
            #expect(AppSettings.transcriptionEngine == .whisper)
        }
    }

    @Test("An unknown stored value falls back to Apple Speech")
    func unknownEngineFallsBack() {
        withDefault(AppSettings.transcriptionEngineKey, set: "garbage") {
            #expect(AppSettings.transcriptionEngine == .appleSpeech)
        }
    }

    @Test("Whisper model defaults to the catalog's recommended variant")
    func whisperModelDefaultsToCatalog() {
        withDefault(AppSettings.whisperModelKey, set: nil) {
            #expect(AppSettings.whisperModel == WhisperModelCatalog.defaultModel.variant)
        }
    }

    @Test("Catalog variants are unique and resolvable")
    func catalogIsConsistent() {
        let variants = WhisperModelCatalog.models.map(\.variant)
        #expect(Set(variants).count == variants.count)
        #expect(!WhisperModelCatalog.models.isEmpty)
        for model in WhisperModelCatalog.models {
            #expect(WhisperModelCatalog.model(for: model.variant) == model)
            #expect(model.approximateMegabytes > 0)
        }
        // The default must be one of the offered models, or the picker would
        // show a selection the user can never see.
        #expect(variants.contains(WhisperModelCatalog.defaultModel.variant))
    }

    @Test("Model store folder follows the hub layout WhisperKit writes into")
    func storeFolderMatchesHubLayout() {
        let folder = WhisperModelStore.folder(for: "openai_whisper-base")
        #expect(folder.path.hasSuffix("WhisperKitModels/models/argmaxinc/whisperkit-coreml/openai_whisper-base"))
        #expect(!WhisperModelStore.isDownloaded("nonexistent-model-variant"))
    }
}

/// The live loop's confirmation split decides which words are shown as final
/// versus still-revisable — an off-by-one here duplicates or drops text.
struct WhisperLiveSplitTests {
    private func segment(_ index: Int) -> TranscriptSegment {
        TranscriptSegment(text: "s\(index)", start: TimeInterval(index), end: TimeInterval(index + 1))
    }

    @MainActor
    @Test("Fewer segments than the hold-back count stay unconfirmed")
    func fewSegmentsStayUnconfirmed() {
        let segments = [segment(0), segment(1)]
        let split = WhisperTranscriptionService.splitForConfirmation(segments, keepingLast: 2)
        #expect(split.confirmed.isEmpty)
        #expect(split.unconfirmed == segments)
    }

    @MainActor
    @Test("Extra segments confirm in order, keeping the trailing ones volatile")
    func confirmsPrefixInOrder() {
        let segments = (0..<5).map(segment)
        let split = WhisperTranscriptionService.splitForConfirmation(segments, keepingLast: 2)
        #expect(split.confirmed == Array(segments.prefix(3)))
        #expect(split.unconfirmed == Array(segments.suffix(2)))
    }

    @MainActor
    @Test("Empty input yields empty output")
    func emptyInput() {
        let split = WhisperTranscriptionService.splitForConfirmation([], keepingLast: 2)
        #expect(split.confirmed.isEmpty)
        #expect(split.unconfirmed.isEmpty)
    }
}

/// The live loop pins the meeting's language for every later pass, so the pin
/// must wait for evidence: one noisy second is enough for Whisper to guess
/// wrong, and a wrong pin transliterates the rest of the meeting.
struct WhisperLanguagePinTests {
    @MainActor
    @Test("Speech seconds sum segment durations, not recorded time")
    func speechSecondsSumSegments() {
        let segments = [
            TranscriptSegment(text: "one", start: 12, end: 14),
            TranscriptSegment(text: "two", start: 14, end: 17.5),
        ]
        // 12 seconds of silence before the first word count for nothing.
        #expect(WhisperTranscriptionService.speechSeconds(of: segments) == 5.5)
        #expect(WhisperTranscriptionService.speechSeconds(of: []) == 0)
    }

    @MainActor
    @Test("One detection is never enough, however much speech it heard")
    func firstDetectionDoesNotPin() {
        #expect(WhisperTranscriptionService.languagePin(detected: "zh", matching: nil, speechSeconds: 60) == nil)
    }

    @MainActor
    @Test("Two consecutive passes must agree")
    func disagreeingPassesDoNotPin() {
        #expect(WhisperTranscriptionService.languagePin(detected: "zh", matching: "en", speechSeconds: 60) == nil)
    }

    @MainActor
    @Test("Agreement on too little speech does not pin")
    func agreementNeedsEnoughSpeech() {
        #expect(WhisperTranscriptionService.languagePin(
            detected: "zh",
            matching: "zh",
            speechSeconds: WhisperTranscriptionService.languagePinMinimumSpeechSeconds - 0.1
        ) == nil)
    }

    @MainActor
    @Test("Agreement plus enough speech pins the language")
    func agreementWithEnoughSpeechPins() {
        #expect(WhisperTranscriptionService.languagePin(
            detected: "zh",
            matching: "zh",
            speechSeconds: WhisperTranscriptionService.languagePinMinimumSpeechSeconds
        ) == "zh")
    }

    @MainActor
    @Test("A pass that detected nothing never pins")
    func missingDetectionDoesNotPin() {
        #expect(WhisperTranscriptionService.languagePin(detected: nil, matching: nil, speechSeconds: 60) == nil)
    }
}

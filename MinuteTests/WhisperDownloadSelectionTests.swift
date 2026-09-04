import Foundation
import Testing
@testable import Minute

/// Deleting the selected model must not leave the selection pointing at bytes
/// that are gone: the next recording would report "the model isn't downloaded"
/// while a downloaded model sits one row below with no checkmark.
@MainActor
struct WhisperDownloadSelectionTests {
    @Test("The most accurate model still downloaded takes the selection")
    func picksTheMostAccurateSurvivor() {
        // The list arrives in catalog order (smallest → most accurate).
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-base", "openai_whisper-small"]
        ) == "openai_whisper-small")
    }

    @Test("Deleting a model that isn't selected changes nothing")
    func leavesAnUnrelatedDeletionAlone() {
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-base",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-small", "openai_whisper-large-v3"]
        ) == nil)
    }

    @Test("With nothing else downloaded the stored selection is left alone")
    func keepsTheSelectionWhenNothingElseIsDownloaded() {
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: []
        ) == nil)
        // The deleted model is never its own replacement, even if a stale
        // caller still lists it.
        #expect(WhisperDownloadCenter.replacementSelection(
            after: "openai_whisper-large-v3",
            selected: "openai_whisper-large-v3",
            downloaded: ["openai_whisper-large-v3"]
        ) == nil)
    }

    @Test("Deleting the real catalog's most accurate model falls back to the one below it")
    func picksTheSurvivorFromTheRealCatalog() throws {
        // The cases above use invented variant names — none of them is a
        // shipping variant, so nothing in this suite proved the function
        // works on the strings it is actually handed. This one runs it over
        // the real catalog.
        let variants = WhisperModelCatalog.models.map(\.variant)
        try #require(variants.count >= 2)
        let deleted = try #require(variants.last)

        #expect(WhisperDownloadCenter.replacementSelection(
            after: deleted,
            selected: deleted,
            downloaded: Array(variants.dropLast())
        ) == variants[variants.count - 2])
    }
}

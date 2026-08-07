import Foundation
import Observation

/// App-scoped download state for Whisper models. A 150–630 MB download
/// outlives the Settings screen, so its task and progress must not live in
/// view state: a returning visit has to show the in-flight download rather
/// than offering a second concurrent Get for the same variant.
@MainActor
@Observable
final class WhisperDownloadCenter {
    static let shared = WhisperDownloadCenter()

    /// variant → fraction complete for in-flight downloads.
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    /// Bumped on EVERY terminal outcome — success, cancel, or failure — so
    /// views refresh their on-disk state without polling. Success-only would
    /// leave a cancelled partial download's Delete action hidden until the
    /// screen is reopened.
    private(set) var finishedCount = 0

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func download(_ model: WhisperModel) {
        let variant = model.variant
        // Already in flight — never start a second task on the same folder.
        guard tasks[variant] == nil else { return }
        errors[variant] = nil
        progress[variant] = 0
        tasks[variant] = Task {
            do {
                try await WhisperModelStore.download(variant) { [weak self] fraction in
                    // A straggler callback can land after cleanup below;
                    // writing then would resurrect a phantom progress row
                    // with no task behind it. Only a live task may report.
                    guard let self, self.tasks[variant] != nil else { return }
                    self.progress[variant] = fraction
                }
                // A cancel that lands at a file boundary makes download()
                // return NORMALLY (WhisperKit checks Task.isCancelled between
                // files with a plain return), so success alone doesn't prove
                // the model is complete — check the disk before selecting.
                if WhisperModelStore.isDownloaded(variant) {
                    // Point the engine at the fresh model unless the stored
                    // selection is a catalog model that's already downloaded.
                    let storedUsable = WhisperModelCatalog.model(for: AppSettings.whisperModel)
                        .map { WhisperModelStore.isDownloaded($0.variant) } ?? false
                    if !storedUsable {
                        UserDefaults.standard.set(variant, forKey: AppSettings.whisperModelKey)
                    }
                }
            } catch {
                // WhisperKit surfaces a user cancel as URLError(.cancelled),
                // never CancellationError — Task.isCancelled is what tells a
                // cancel (silent; partial files stay for a later resume)
                // apart from a real failure.
                if !Task.isCancelled {
                    errors[variant] = "The download failed: \(error.localizedDescription)"
                }
            }
            progress[variant] = nil
            tasks[variant] = nil
            finishedCount += 1
        }
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.variant]?.cancel()
    }
}

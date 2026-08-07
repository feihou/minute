import Foundation
import Observation

/// App-scoped download state for summary models. A 1–2.3 GB download
/// outlives the Settings screen, so its task and progress must not live in
/// view state: a returning visit has to show the in-flight download rather
/// than offering a second concurrent Get for the same repo.
@MainActor
@Observable
final class MLXDownloadCenter {
    static let shared = MLXDownloadCenter()

    /// repoID → fraction complete for in-flight downloads.
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    /// Bumped on EVERY terminal outcome — success, cancel, or failure — so
    /// views refresh their on-disk state without polling. Success-only would
    /// leave a cancelled partial download's Delete action hidden until the
    /// screen is reopened.
    private(set) var finishedCount = 0

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func download(_ model: MLXSummaryModel) {
        let repoID = model.repoID
        // Already in flight — never start a second task on the same cache.
        guard tasks[repoID] == nil else { return }
        errors[repoID] = nil
        progress[repoID] = 0
        tasks[repoID] = Task {
            do {
                try await MLXModelStore.download(model) { [weak self] fraction in
                    // A straggler callback can land after cleanup below;
                    // writing then would resurrect a phantom progress row
                    // with no task behind it. Only a live task may report.
                    guard let self, self.tasks[repoID] != nil else { return }
                    self.progress[repoID] = fraction
                }
                // Point the engine at the fresh model when the stored
                // selection can't work — not downloaded, or removed from the
                // catalog by an app update.
                let stored = AppSettings.localSummaryModel
                let storedUsable = MLXModelCatalog.model(for: stored).map(MLXModelStore.isDownloaded) ?? false
                if !storedUsable {
                    UserDefaults.standard.set(repoID, forKey: AppSettings.localSummaryModelKey)
                }
            } catch is CancellationError {
                // User cancelled — partial files stay for a later resume.
            } catch {
                errors[repoID] = "The download failed: \(error.localizedDescription)"
            }
            progress[repoID] = nil
            tasks[repoID] = nil
            finishedCount += 1
        }
    }

    func cancel(_ model: MLXSummaryModel) {
        tasks[model.repoID]?.cancel()
    }
}

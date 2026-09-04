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

    /// repoID → a non-failure explanation for a stopped download. iOS ending
    /// the app's background window is not a failure: the partial files stay
    /// on disk and Get resumes, so this renders in secondary text while
    /// `errors` stays red.
    private(set) var notices: [String: String] = [:]

    /// Shown when iOS ended the background window mid-download.
    static let backgroundPauseNotice = "Paused when Minute went to the background. Tap Get to resume."

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func download(_ model: MLXSummaryModel) {
        let repoID = model.repoID
        // Already in flight — never start a second task on the same cache.
        guard tasks[repoID] == nil else { return }
        errors[repoID] = nil
        notices[repoID] = nil
        progress[repoID] = 0
        tasks[repoID] = Task {
            // A 1-2.3 GB transfer over an ordinary URLSession dies the moment
            // iOS suspends the app, which happens seconds after the user
            // switches away. The token buys the OS-granted window; when it
            // expires we cancel the transfer ourselves so it ends as a
            // resumable pause with the partial files kept, instead of a
            // "the network connection was lost" error the user reads as a
            // failure of the download itself.
            let token = BackgroundTaskToken(name: "Summary model download") { [weak self] in
                guard let self else { return }
                self.notices[repoID] = Self.backgroundPauseNotice
                self.tasks[repoID]?.cancel()
            }
            defer { token.end() }
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
            } catch {
                // URLSession surfaces a user cancel as URLError(.cancelled),
                // not CancellationError — the task's own flag is the reliable
                // signal. Cancelled partial files stay for a later resume.
                if !Task.isCancelled {
                    errors[repoID] = "The download failed: \(error.localizedDescription)"
                }
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

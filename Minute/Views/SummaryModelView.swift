import SwiftUI

/// Picks the summarization engine and, for the local model, manages the
/// downloadable models: get, select, and delete, with per-model progress.
/// Models the device can't hold are shown but not selectable.
struct SummaryModelView: View {
    @AppStorage(AppSettings.summarizationEngineKey) private var engineRaw = SummarizationEngineChoice.appleIntelligence.rawValue
    @AppStorage(AppSettings.localSummaryModelKey) private var selectedRepoID = MLXModelCatalog.defaultModel.repoID

    /// repoID → fraction complete for in-flight downloads.
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadErrors: [String: String] = [:]
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var deletingModel: MLXSummaryModel?

    private var engine: SummarizationEngineChoice {
        SummarizationEngineChoice(rawValue: engineRaw) ?? .appleIntelligence
    }

    var body: some View {
        List {
            engineSection
            if engine == .localModel {
                modelSection
            }
        }
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshDownloaded() }
        .confirmationDialog(
            "Delete this model?",
            isPresented: Binding(
                get: { deletingModel != nil },
                set: { if !$0 { deletingModel = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingModel
        ) { model in
            Button("Delete \(model.label)", role: .destructive) {
                MLXModelStore.delete(model)
                refreshDownloaded()
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Frees about \(model.approximateMegabytes) MB. You can download it again anytime.")
        }
    }

    private var engineSection: some View {
        Section {
            ForEach(SummarizationEngineChoice.allCases) { choice in
                Button {
                    engineRaw = choice.rawValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label)
                                .foregroundStyle(.primary)
                            Text(choice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if engine == choice {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Both engines write the notes entirely on this iPhone. The local model is an open model that works without Apple Intelligence — summaries take longer and use more battery.")
        }
    }

    private var modelSection: some View {
        Section {
            if let selected = MLXModelCatalog.model(for: selectedRepoID),
               !downloadedModels.contains(selected.repoID) {
                Label(
                    "Download a model to use local summaries. Until then, generating notes reports the model as missing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            ForEach(MLXModelCatalog.models) { model in
                modelRow(model)
            }
        } header: {
            Text("Local Model")
        } footer: {
            Text("Models are downloaded once from Hugging Face and stored on this iPhone — your transcripts are never uploaded. Larger models write better notes but need more memory and battery.")
        }
    }

    @ViewBuilder private func modelRow(_ model: MLXSummaryModel) -> some View {
        let isDownloaded = downloadedModels.contains(model.repoID)
        let isSupported = MLXModelCatalog.deviceSupports(model)
        HStack {
            Button {
                selectedRepoID = model.repoID
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .foregroundStyle(isSupported ? .primary : .secondary)
                    Text(rowDetail(model, isDownloaded: isDownloaded, isSupported: isSupported))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = downloadErrors[model.repoID] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded || !isSupported)

            Spacer()

            if let progress = downloadProgress[model.repoID] {
                ProgressView(value: progress)
                    .frame(width: 56)
                Button {
                    downloadTasks[model.repoID]?.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else if isDownloaded {
                if selectedRepoID == model.repoID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            } else if isSupported {
                Button("Get") {
                    download(model)
                }
                .buttonStyle(.bordered)
                .font(.callout.weight(.semibold))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isDownloaded {
                Button(role: .destructive) {
                    deletingModel = model
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func rowDetail(_ model: MLXSummaryModel, isDownloaded: Bool, isSupported: Bool) -> String {
        if !isSupported {
            return "Needs an iPhone with more memory."
        }
        if isDownloaded {
            return model.detail
        }
        return "\(model.detail) About \(model.approximateMegabytes) MB."
    }

    // MARK: - Actions

    private func refreshDownloaded() {
        downloadedModels = Set(
            MLXModelCatalog.models.filter(MLXModelStore.isDownloaded).map(\.repoID)
        )
    }

    private func download(_ model: MLXSummaryModel) {
        let repoID = model.repoID
        downloadErrors[repoID] = nil
        downloadProgress[repoID] = 0
        // ponytail: the download lives in view state — leaving this screen
        // lets it finish in the background, but force-quitting abandons it.
        // Partial files are kept, so a retry resumes where it stopped.
        downloadTasks[repoID] = Task {
            do {
                try await MLXModelStore.download(model) { fraction in
                    downloadProgress[repoID] = fraction
                }
                downloadedModels.insert(repoID)
                if let selected = MLXModelCatalog.model(for: selectedRepoID),
                   !downloadedModels.contains(selected.repoID) {
                    selectedRepoID = repoID
                }
            } catch is CancellationError {
                // User cancelled — partial files stay for a later resume.
            } catch {
                downloadErrors[repoID] = "The download failed: \(error.localizedDescription)"
            }
            downloadProgress[repoID] = nil
            downloadTasks[repoID] = nil
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SummaryModelView()
    }
}
#endif

import SwiftUI

/// Picks the transcription engine and, for Whisper, manages the downloadable
/// models: get, select, and delete, with per-model progress.
struct TranscriptionModelView: View {
    @AppStorage(AppSettings.transcriptionEngineKey) private var engineRaw = TranscriptionEngineChoice.appleSpeech.rawValue
    @AppStorage(AppSettings.whisperModelKey) private var selectedVariant = WhisperModelCatalog.defaultModel.variant

    /// variant → fraction complete for in-flight downloads.
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadErrors: [String: String] = [:]
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var downloadedVariants: Set<String> = []
    @State private var deletingModel: WhisperModel?

    private var engine: TranscriptionEngineChoice {
        TranscriptionEngineChoice(rawValue: engineRaw) ?? .appleSpeech
    }

    var body: some View {
        List {
            engineSection
            if engine == .whisper {
                modelSection
            }
        }
        .navigationTitle("Transcription")
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
                WhisperModelStore.delete(model.variant)
                refreshDownloaded()
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Frees about \(model.approximateMegabytes) MB. You can download it again anytime.")
        }
    }

    private var engineSection: some View {
        Section {
            ForEach(TranscriptionEngineChoice.allCases) { choice in
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
            Text("Apple Speech transcribes in this iPhone's language. Whisper detects the spoken language automatically — English, Chinese, Spanish, and about 100 more — and uses more battery while recording. Both transcribe live, entirely on this iPhone.")
        }
    }

    private var modelSection: some View {
        Section {
            if !downloadedVariants.contains(selectedVariant) {
                Label(
                    "Download a model to use Whisper. Until then, meetings are saved without a transcript — you can re-transcribe them later.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            ForEach(WhisperModelCatalog.models) { model in
                modelRow(model)
            }
        } header: {
            Text("Whisper Model")
        } footer: {
            Text("Models are downloaded once from Hugging Face and stored on this iPhone — your recordings are never uploaded. Larger models are more accurate but slower, and use more battery during recording.")
        }
    }

    @ViewBuilder private func modelRow(_ model: WhisperModel) -> some View {
        let isDownloaded = downloadedVariants.contains(model.variant)
        HStack {
            Button {
                selectedVariant = model.variant
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .foregroundStyle(.primary)
                    Text(isDownloaded ? model.detail : "\(model.detail) About \(model.approximateMegabytes) MB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = downloadErrors[model.variant] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)

            Spacer()

            if let progress = downloadProgress[model.variant] {
                ProgressView(value: progress)
                    .frame(width: 56)
                Button {
                    cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else if isDownloaded {
                if selectedVariant == model.variant {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            } else {
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

    // MARK: - Actions

    private func refreshDownloaded() {
        downloadedVariants = Set(
            WhisperModelCatalog.models.map(\.variant).filter(WhisperModelStore.isDownloaded)
        )
    }

    private func download(_ model: WhisperModel) {
        let variant = model.variant
        downloadErrors[variant] = nil
        downloadProgress[variant] = 0
        // ponytail: the download lives in view state — leaving this screen
        // lets it finish in the background, but force-quitting abandons it.
        // Partial files are kept, so a retry resumes where it stopped.
        downloadTasks[variant] = Task {
            do {
                try await WhisperModelStore.download(variant) { fraction in
                    downloadProgress[variant] = fraction
                }
                downloadedVariants.insert(variant)
                // Point the engine at the fresh model unless a downloaded one
                // is already selected.
                if !downloadedVariants.contains(selectedVariant) {
                    selectedVariant = variant
                }
            } catch is CancellationError {
                // User cancelled — partial files stay for a later resume.
            } catch {
                downloadErrors[variant] = "The download failed: \(error.localizedDescription)"
            }
            downloadProgress[variant] = nil
            downloadTasks[variant] = nil
        }
    }

    private func cancelDownload(_ model: WhisperModel) {
        downloadTasks[model.variant]?.cancel()
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TranscriptionModelView()
    }
}
#endif

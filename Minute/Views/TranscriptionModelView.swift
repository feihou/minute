import SwiftUI

/// Picks the transcription engine and, for Whisper, manages the downloadable
/// models: get, select, and delete, with per-model progress.
struct TranscriptionModelView: View {
    @AppStorage(AppSettings.transcriptionEngineKey) private var engineRaw = TranscriptionEngineChoice.appleSpeech.rawValue
    @AppStorage(AppSettings.whisperModelKey) private var selectedVariant = WhisperModelCatalog.defaultModel.variant

    /// App-scoped, deliberately not view state: a download must survive this
    /// screen being popped, and a returning visit must see it instead of
    /// offering a second concurrent Get.
    private let downloads = WhisperDownloadCenter.shared
    @State private var downloadedVariants: Set<String> = []
    /// Variants with only partial files on disk (cancelled or failed
    /// downloads) — still deletable so the stranded space can be reclaimed.
    @State private var partialVariants: Set<String> = []
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
        .onChange(of: downloads.finishedCount) { refreshDownloaded() }
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
                // The deleted model may have been the selected one. Leaving
                // the selection there makes the next recording report "the
                // model isn't downloaded" while a downloaded model sits one
                // row below with no checkmark. selectedVariant is the
                // @AppStorage on AppSettings.whisperModelKey, so writing it
                // stores the new selection.
                if let replacement = WhisperDownloadCenter.replacementSelection(
                    after: model.variant,
                    selected: AppSettings.whisperModel,
                    downloaded: WhisperModelCatalog.models.map(\.variant).filter(WhisperModelStore.isDownloaded)
                ) {
                    selectedVariant = replacement
                }
                refreshDownloaded()
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Frees up to about \(model.approximateMegabytes) MB. You can download it again anytime.")
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
        let isDownloading = downloads.progress[model.variant] != nil
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
                    if let error = downloads.errors[model.variant] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)

            Spacer()

            if let progress = downloads.progress[model.variant] {
                ProgressView(value: progress)
                    .frame(width: 56)
                Button {
                    downloads.cancel(model)
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
                    downloads.download(model)
                }
                .buttonStyle(.bordered)
                .font(.callout.weight(.semibold))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Partial downloads are deletable too — stranded megabytes from a
            // cancelled or disk-full download must be reclaimable.
            if !isDownloading, isDownloaded || partialVariants.contains(model.variant) {
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
        partialVariants = Set(
            WhisperModelCatalog.models.map(\.variant)
                .filter { !WhisperModelStore.isDownloaded($0) && WhisperModelStore.hasLocalData($0) }
        )
        // The download center writes the selection key directly when a
        // download finishes; KVO reads the dotted key as a key path, so
        // @AppStorage never hears about that write — re-read it here.
        selectedVariant = AppSettings.whisperModel
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        TranscriptionModelView()
    }
}
#endif

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
    /// Variants downloaded before the tokenizer counted as part of the model:
    /// the weights are here, a few megabytes of JSON are not. The row offers
    /// Update rather than a full Get.
    @State private var updatableVariants: Set<String> = []
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
            if updatableVariants.contains(selectedVariant) {
                // The model is here; only its tokenizer is missing. Telling
                // this user to "download a model" contradicts the download
                // they already did.
                Label(
                    "The Whisper model needs a small one-time update — tap Update below. Until then, meetings are saved without a transcript — you can re-transcribe them later.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else if !downloadedVariants.contains(selectedVariant) {
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
        let needsUpdate = updatableVariants.contains(model.variant)
        let isDownloading = downloads.progress[model.variant] != nil
        HStack {
            Button {
                selectedVariant = model.variant
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label)
                        .foregroundStyle(.primary)
                    Text(sizeDetail(for: model, isDownloaded: isDownloaded, needsUpdate: needsUpdate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = downloads.errors[model.variant] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let notice = downloads.notices[model.variant] {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                // Same action either way — the download resumes over what is
                // already there and fetches only what is missing — but the
                // word has to match what it costs: "Get" over a model the user
                // already downloaded reads as a second 626 MB fetch.
                Button(needsUpdate ? "Update" : "Get") {
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

    // MARK: - Row copy

    /// The line under a model's name. A model waiting for its tokenizer names
    /// the size of THAT fetch, not the size of the download it already has.
    private func sizeDetail(for model: WhisperModel, isDownloaded: Bool, needsUpdate: Bool) -> String {
        if isDownloaded { return model.detail }
        if needsUpdate { return "\(model.detail) \(WhisperModelStore.tokenizerUpdateSizeText)" }
        return "\(model.detail) About \(model.approximateMegabytes) MB."
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
        updatableVariants = Set(
            WhisperModelCatalog.models.map(\.variant).filter(WhisperModelStore.needsTokenizerUpdate)
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

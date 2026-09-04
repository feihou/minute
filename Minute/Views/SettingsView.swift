import AVFoundation
import Speech
import SwiftData
import SwiftUI
import UIKit

/// Recording preferences, storage management, privacy explanation, and
/// on-device capability status.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(MeetingJobs.self) private var jobs
    @Query private var meetings: [Meeting]

    @AppStorage(AppSettings.audioQualityKey) private var audioQualityRaw = AudioQuality.high.rawValue
    @AppStorage(AppSettings.liveTranscriptionKey) private var liveTranscription = true
    @AppStorage(AppSettings.autoSummarizeKey) private var autoSummarize = false
    @AppStorage(AppSettings.summaryTemplateKey) private var summaryTemplate = SummaryTemplate.standard.id
    @AppStorage(AppSettings.summaryContextKey) private var summaryContext = ""
    @AppStorage(AppSettings.summaryLanguageKey) private var summaryLanguage = ""
    @AppStorage(AppSettings.transcriptionEngineKey) private var transcriptionEngineRaw = TranscriptionEngineChoice.appleSpeech.rawValue
    @AppStorage(AppSettings.whisperModelKey) private var whisperModelRaw = ""
    @AppStorage(AppSettings.summarizationEngineKey) private var summarizationEngineRaw = SummarizationEngineChoice.appleIntelligence.rawValue
    @AppStorage(AppSettings.localSummaryModelKey) private var localSummaryModelRaw = ""
    @AppStorage(AppSettings.iCloudBackupKey) private var iCloudBackup = false
    @AppStorage(AppSettings.iCloudDriveKey) private var iCloudDrive = false
    // Persisted, not @State: resolving the iCloud container on first use is
    // slow, and dismissing Settings before it returns would otherwise discard
    // the explanation and leave the toggle mysteriously back off.
    @AppStorage(AppSettings.iCloudDriveUnavailableKey) private var driveUnavailable = false
    @AppStorage(AppSettings.iCloudDriveLastSyncFailedKey) private var driveLastSyncFailed = false

    @State private var transcriptionStatus = "Checking…"
    @State private var usage: (fileCount: Int, totalBytes: Int64) = (0, 0)
    @State private var confirmingDeleteAll = false
    @State private var deleteAllFailed = false
    @State private var backupPolicyFailed = false
    @State private var mirrorTask: Task<Void, Never>?
    @State private var confirmingStoreReset = false
    @State private var storeResetFailed = false
    /// Set once the reset has run. The process keeps the in-memory container
    /// it opened at launch, so the library only comes back empty-and-working
    /// after a relaunch — the row says so instead of leaving the user to
    /// wonder why nothing changed.
    @State private var didResetStore = false

    var body: some View {
        NavigationStack {
            List {
                identitySection
                recordingSection
                summaryContextSection
                modelsSection
                // In fallback mode the usage figure and the local deletion
                // promise would both be wrong — the usage row counts the
                // session-only tmp directory, and Delete All Meetings iterates
                // an empty in-memory library — so that mode gets its own
                // section, which is also the only way out of it. Backup
                // controls stay visible in both: the device-backup choice
                // still governs old persistent data, and the user must be able
                // to turn either privacy setting off.
                if MeetingStore.useEphemeralStorage {
                    fallbackStorageSection
                } else {
                    storageSection
                }
                backupSection
                privacySection
                capabilitiesSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // task(id:) so returning from an engine/model picker refreshes the
            // capability rows without reopening Settings; see modelStatusKey
            // for why both download centers are part of the key.
            .task(id: modelStatusKey) { await refreshTranscriptionStatus() }
            .task { usage = MeetingStore.recordingsUsage() }
            // The background mirror records its verdict with a direct
            // UserDefaults write, which @AppStorage does not observe on these
            // dotted keys — so while this sheet stays open across a
            // background/foreground cycle the warning below is stale in both
            // directions. Most concretely: the user reads the warning, leaves
            // to sign in to iCloud (which backgrounds the app and runs a now
            // successful mirror), comes back, and the warning is still there.
            .onChange(of: scenePhase) {
                guard scenePhase == .active else { return }
                driveLastSyncFailed = AppSettings.iCloudDriveLastSyncFailed
            }
            .confirmationDialog(
                "Delete all meetings?",
                isPresented: $confirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    deleteAllMeetings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every meeting, recording, transcript, and summary — and everything Brain learned from them — will be permanently deleted from this iPhone.")
            }
            .alert("Couldn't update backup setting", isPresented: $backupPolicyFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Storage may be unavailable. Your choice is saved and will be applied automatically the next time the app launches.")
            }
            .alert(
                MeetingStore.useEphemeralStorage
                    ? "Storage isn't available"
                    : "iCloud Drive isn't available",
                isPresented: $driveUnavailable
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                if MeetingStore.useEphemeralStorage {
                    // Same failure the Storage section describes, so it can't
                    // promise a recovery that section says only a reset brings.
                    Text("Minute couldn't open its meeting store and is keeping this session in memory only. The Storage section in Settings explains it and offers the reset.")
                } else {
                    Text("Sign in to iCloud and turn on iCloud Drive in iOS Settings, then try again. A build signed without iCloud entitlements can't use this.")
                }
            }
            .alert("Some meetings couldn't be deleted", isPresented: $deleteAllFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Storage may be unavailable. The remaining meetings are still in your library — try again later.")
            }
            .confirmationDialog(
                "Delete stored meetings and start over?",
                isPresented: $confirmingStoreReset,
                titleVisibility: .visible
            ) {
                Button("Delete and Start Over", role: .destructive) {
                    resetStoredMeetings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The unreadable meeting database and every recording still on this iPhone will be permanently deleted. This can't be undone.")
            }
            .alert("Couldn't delete the stored meetings", isPresented: $storeResetFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Some files couldn't be removed. Storage may be unavailable — try again later.")
            }
        }
    }

    // MARK: - Sections

    /// Sits on the grouped background rather than in a row: this is the sheet's
    /// masthead, not a setting the user can act on.
    private var identitySection: some View {
        Section {
            VStack(spacing: 10) {
                BrandIconTile(size: 58, cornerRadius: 14, iconSize: 24)
                Text("Minute")
                    .font(.title3.weight(.semibold))
                Text("Meetings are processed entirely on this iPhone; cloud backups are optional.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .combine)
        }
    }

    private var recordingSection: some View {
        Section {
            Picker(selection: $audioQualityRaw) {
                ForEach(AudioQuality.allCases) { quality in
                    Text(quality.label).tag(quality.rawValue)
                }
            } label: {
                settingsLabel("Audio Quality", systemImage: "waveform", tint: .indigo)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $liveTranscription) {
                settingsLabel("Live Transcription", systemImage: "captions.bubble", tint: .blue)
            }

            // Deliberately not gated on Live Transcription: this setting also
            // governs imported audio (MeetingListView.startImport reads it,
            // and AudioImporter transcribes regardless of the live setting).
            // Gating it left a user who records without live transcription
            // unable to turn it on for imports at all — and left it stuck ON,
            // greyed out and looking inert, while imports kept auto-summarizing.
            Toggle(isOn: $autoSummarize) {
                settingsLabel("Auto-Summarize", systemImage: "sparkles", tint: .purple)
            }

            Picker(selection: $summaryTemplate) {
                ForEach(SummaryTemplate.all) { template in
                    Text(template.name).tag(template.id)
                }
            } label: {
                settingsLabel("Summary Template", systemImage: "square.grid.2x2", tint: .teal)
            }
            .pickerStyle(.menu)

            Picker(selection: $summaryLanguage) {
                Text("Match Meeting").tag("")
                ForEach(AppSettings.summaryLanguageOptions, id: \.self) { language in
                    Text(language).tag(language)
                }
            } label: {
                settingsLabel("Summary Language", systemImage: "globe", tint: .cyan)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Recording")
        } footer: {
            Text("\(selectedQuality.label): \(selectedQuality.detail). Settings apply to new recordings. Auto-Summarize generates the summary on device as soon as a meeting has a transcript — after a recording made with Live Transcription on, and after importing audio. The template controls how notes are organized (e.g. Yesterday/Today/Blockers for standups).")
        }
    }

    private var summaryContextSection: some View {
        Section {
            TextField("Names, projects, terms…", text: $summaryContext, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("Summary Context")
        } footer: {
            Text("Optional background the AI reads with every summary — attendee names, project names, and terms it should spell correctly. Stays on device.")
        }
    }

    private var transcriptionModelName: String {
        switch AppSettings.transcriptionEngine {
        case .appleSpeech:
            return "Apple Speech"
        case .whisper:
            let label = WhisperModelCatalog.model(for: AppSettings.whisperModel)?.label ?? "Custom"
            return "Whisper · \(label)"
        }
    }

    private var summaryModelName: String {
        switch AppSettings.summarizationEngine {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .localModel:
            return MLXModelCatalog.model(for: AppSettings.localSummaryModel)?.label ?? "Local Model"
        }
    }

    private var modelsSection: some View {
        Section {
            NavigationLink {
                TranscriptionModelView()
            } label: {
                LabeledContent {
                    Text(transcriptionModelName)
                        .foregroundStyle(.secondary)
                } label: {
                    settingsLabel("Transcription Model", systemImage: "text.bubble", tint: .blue)
                }
            }
            NavigationLink {
                SummaryModelView()
            } label: {
                LabeledContent {
                    Text(summaryModelName)
                        .foregroundStyle(.secondary)
                } label: {
                    settingsLabel("Summary Model", systemImage: "brain", tint: .purple)
                }
            }
            LabeledContent {
                Text("FluidAudio")
                    .foregroundStyle(.secondary)
            } label: {
                settingsLabel("Speaker Model", systemImage: "person.2.wave.2", tint: .teal)
            }
        } header: {
            Text("Models")
        } footer: {
            Text(
                "Transcription and summaries run entirely on this iPhone; the Apple models may need a one-time download before first use. "
                + "The speaker model (FluidAudio) and any Whisper transcription or local summary models you choose are downloaded once from Hugging Face and then cached — those model downloads are Minute's only non-Apple requests, and your recordings are never part of them. "
                + "If you enable iCloud backups or the iCloud Drive folder, Apple may also sync meeting copies to your own account."
            )
        }
    }

    private var storageSection: some View {
        Section {
            HStack {
                settingsLabel("Recordings", systemImage: "internaldrive", tint: .gray)
                Spacer()
                Text(usageText)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                confirmingDeleteAll = true
            } label: {
                settingsLabel("Delete All Meetings", systemImage: "trash", tint: .red)
                    .foregroundStyle(.red)
            }
            .disabled(meetings.isEmpty)
        } header: {
            Text("Storage")
        } footer: {
            Text("Deleting removes every meeting, its audio, transcript, and summary from this iPhone, along with everything Brain learned from it. This can't be undone.")
        }
    }

    /// The way out of fallback mode, and the only delete path the on-disk
    /// audio and transcripts have while it lasts.
    private var fallbackStorageSection: some View {
        Section {
            if let message = AppSettings.persistentStoreFailure {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if didResetStore {
                Label("Quit and reopen Minute to finish.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                Button(role: .destructive) {
                    confirmingStoreReset = true
                } label: {
                    settingsLabel("Delete stored meetings and start over", systemImage: "trash", tint: .red)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Minute couldn't open its meeting database, so nothing from this session is being saved. Deleting removes that database and every recording still on this iPhone, and the next launch starts with an empty library. This can't be undone.")
        }
    }

    private var backupSection: some View {
        Section {
            Toggle(isOn: $iCloudBackup) {
                settingsLabel("iCloud Backup", systemImage: "icloud", tint: .blue)
            }
            .onChange(of: iCloudBackup) {
                // A privacy control must not fail silently; the choice is
                // saved and re-applied at every launch, so it self-heals.
                backupPolicyFailed = !MeetingStore.applyBackupPolicy()
            }

            Toggle(isOn: $iCloudDrive) {
                settingsLabel("iCloud Drive Folder", systemImage: "folder.badge.plus", tint: .cyan)
            }
            .onChange(of: iCloudDrive) {
                // Switching off must stop a mirror already in flight, or it
                // keeps copying recordings into iCloud that no later sync
                // will clean up — the opt-out has to mean something.
                mirrorTask?.cancel()
                // A stale verdict from a previous state helps nobody: turning
                // the mirror off retires it, turning it on re-tests it.
                driveLastSyncFailed = false
                guard iCloudDrive else { return }
                let request = ICloudDriveBackup.request(for: meetings)
                mirrorTask = Task {
                    // Toggling on is the one moment to say "this can't work
                    // here" — afterwards the mirror quietly self-heals.
                    let outcome = await ICloudDriveBackup.syncNow(request)
                    // Resolving the iCloud container is slow on first use;
                    // never overrule a choice the user made since then.
                    guard !Task.isCancelled, iCloudDrive else { return }
                    switch outcome {
                    case .unavailable:
                        // The feature genuinely cannot work here, so retiring
                        // the toggle is the honest outcome.
                        iCloudDrive = false
                        driveUnavailable = true
                    case .incomplete:
                        // One meeting that wouldn't copy is no reason to switch
                        // the whole backup off — that would also deny it the
                        // background retry that heals exactly this. Leave it on
                        // and report the incompleteness instead.
                        driveLastSyncFailed = true
                    case .complete, .interrupted:
                        break
                    }
                }
            }

            if iCloudDrive, driveLastSyncFailed {
                Label(
                    "The last backup to iCloud Drive didn't finish. Check that you're signed in to iCloud with iCloud Drive on — Minute will try again next time you leave the app.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Backup")
        } footer: {
            if MeetingStore.useEphemeralStorage {
                // "Temporarily unavailable" was written before the Storage
                // section above existed: that section says the store could not
                // be opened at all and offers the reset that is the only way
                // out. Two sections about the same failure must not disagree
                // about whether it passes on its own.
                Text("Minute couldn't open its meeting store — see the Storage section above. iCloud Backup still controls whether existing on-device data is included in future device backups, and either backup option can still be turned off. iCloud Drive Folder can't start a new mirror until the store opens again.")
            } else {
                Text("Both are off by default. iCloud Backup includes meeting data in this iPhone's device backup — it comes back only by restoring the iPhone from that backup. iCloud Drive Folder keeps a browsable copy in Files → iCloud Drive → Minute → this iPhone's folder (one folder per meeting with its notes and audio), updated when you leave the app. Turning either off stops future copies; files already in iCloud Drive stay until you delete them in Files. Nothing else is uploaded — there is still no account and no server.")
            }
        }
    }

    /// These are statements, not settings. They get plain glyphs instead of the
    /// filled tiles the tappable rows use — four gradient tiles on four
    /// sentences reads as chrome and makes the prose harder to scan.
    private var privacySection: some View {
        Section("Privacy") {
            VStack(alignment: .leading, spacing: 14) {
                privacyLine("iphone", "Recordings, transcripts, and summaries stay on this iPhone unless you turn on an iCloud backup option above.")
                privacyLine("cpu", "Transcription and summarization run entirely on device.")
                privacyLine("person.crop.circle.badge.xmark", "No account, no analytics, no tracking.")
                privacyLine("exclamationmark.bubble",
                            "Recording laws differ by region — always tell everyone in the room before recording.",
                            tint: .orange)
            }
            .padding(.vertical, 6)
        }
    }

    private func privacyLine(_ systemImage: String, _ text: String, tint: Color = .green) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var capabilitiesSection: some View {
        Section {
            LabeledContent {
                Text(microphoneStatus)
            } label: {
                settingsLabel("Microphone", systemImage: "mic", tint: .red)
            }
            LabeledContent {
                Text(transcriptionStatus)
            } label: {
                settingsLabel("Transcription", systemImage: "text.bubble", tint: .blue)
            }
            LabeledContent {
                Text(summarizationStatus)
            } label: {
                settingsLabel("Summarization", systemImage: "brain", tint: .purple)
            }
            if let message = SummarizationEngines.availabilityMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On-Device Capabilities")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(appVersion)
            } label: {
                settingsLabel("Version", systemImage: "info.circle", tint: .gray)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                settingsLabel("Open iOS Settings", systemImage: "gear", tint: .gray)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Manage microphone access and Apple Intelligence in iOS Settings.")
        }
    }

    // MARK: - Row pieces

    private func settingsLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
        }
    }

    // MARK: - Derived state

    private var selectedQuality: AudioQuality {
        AudioQuality(rawValue: audioQualityRaw) ?? .high
    }

    private var usageText: String {
        let size = usage.totalBytes.formatted(.byteCount(style: .file))
        return usage.fileCount == 1 ? "1 recording · \(size)" : "\(usage.fileCount) recordings · \(size)"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var microphoneStatus: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .undetermined: return "Asked on first recording"
        @unknown default: return "Unknown"
        }
    }

    private var summarizationStatus: String {
        SummarizationEngines.availabilityMessage == nil ? "Ready" : "Unavailable"
    }

    // MARK: - Actions

    private func deleteAllMeetings() {
        var allSucceeded = true
        for meeting in meetings {
            // A summary or re-transcription still running on this meeting would
            // keep decoding a deleted file for minutes; stop it first.
            jobs.cancel(meeting)
            if !MeetingStore.delete(meeting, context: context) {
                allSucceeded = false
            }
        }
        usage = MeetingStore.recordingsUsage()
        deleteAllFailed = !allSucceeded
    }

    /// Fallback mode only. Deletes the unreadable store and the recordings it
    /// stranded; the persistent container is only re-created at the next
    /// launch, so success asks for a relaunch rather than claiming the library
    /// is back.
    private func resetStoredMeetings() {
        if MeetingStore.resetPersistentStore() {
            didResetStore = true
        } else {
            storeResetFailed = true
        }
    }

    /// Everything whose change has to re-run the capability check and re-read
    /// the model rows. Both centers' `finishedCount` is in here because a
    /// download can finish — and auto-select the model it just fetched — after
    /// its picker has been popped, and @AppStorage never observes the center's
    /// direct write to the dotted selection key. Reading them during `body` is
    /// also what makes the plain computed rows (`summaryModelName`, the
    /// availability footnote, `summarizationStatus`) re-evaluate at all: the
    /// summary side had no dependency on MLXDownloadCenter, so a finished
    /// ~1 GB download kept reading "Local Model / Unavailable / not downloaded
    /// yet" until Settings was dismissed and reopened.
    private var modelStatusKey: String {
        "\(transcriptionEngineRaw)|\(whisperModelRaw)|\(WhisperDownloadCenter.shared.finishedCount)|\(MLXDownloadCenter.shared.finishedCount)"
    }

    private func refreshTranscriptionStatus() async {
        if AppSettings.transcriptionEngine == .whisper {
            if WhisperModelStore.isDownloaded(AppSettings.whisperModel) {
                transcriptionStatus = "Ready"
            } else if WhisperModelStore.needsTokenizerUpdate(AppSettings.whisperModel) {
                // The model is downloaded; only its tokenizer is missing. This
                // row must not tell someone who has the model that they don't.
                transcriptionStatus = "Update needed"
            } else {
                transcriptionStatus = "Model not downloaded"
            }
            return
        }
        guard SpeechTranscriber.isAvailable else {
            transcriptionStatus = "Not supported"
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            transcriptionStatus = "Language not supported"
            return
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            transcriptionStatus = "Ready"
        } else {
            transcriptionStatus = "Model downloads on first recording"
        }
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .modelContainer(MeetingStore.previewContainer())
        .environment(MeetingJobs())
}
#endif

import AVFoundation
import Speech
import SwiftData
import SwiftUI
import UIKit

/// Recording preferences, storage management, privacy explanation, and
/// on-device capability status.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var meetings: [Meeting]

    @AppStorage(AppSettings.audioQualityKey) private var audioQualityRaw = AudioQuality.high.rawValue
    @AppStorage(AppSettings.liveTranscriptionKey) private var liveTranscription = true
    @AppStorage(AppSettings.autoSummarizeKey) private var autoSummarize = false

    @State private var transcriptionStatus = "Checking…"
    @State private var usage: (fileCount: Int, totalBytes: Int64) = (0, 0)
    @State private var confirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                identitySection
                recordingSection
                // In ephemeral-fallback mode the real recordings directory
                // isn't in use, so the usage figure and the "delete all"
                // promise would both be wrong — hide the section entirely.
                if !MeetingStore.useEphemeralStorage {
                    storageSection
                }
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
            .task { await refreshTranscriptionStatus() }
            .task { usage = MeetingStore.recordingsUsage() }
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
                Text("Every meeting, recording, transcript, and summary will be permanently deleted from this iPhone.")
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient.brand)
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Minute")
                        .font(.headline)
                    Text("Meetings recorded, transcribed, and summarized — entirely on this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
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

            Toggle(isOn: $autoSummarize) {
                settingsLabel("Auto-Summarize", systemImage: "sparkles", tint: .purple)
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("\(selectedQuality.label): \(selectedQuality.detail). Live transcription and auto-summarize apply to new recordings; the summary is generated on device right after a meeting is saved.")
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
            Text("Deleting removes every meeting, its audio, transcript, and summary from this iPhone. This can't be undone.")
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            settingsLabel("Recordings, transcripts, and summaries stay on this iPhone.",
                          systemImage: "iphone", tint: .green)
            settingsLabel("Transcription and summarization run entirely on device.",
                          systemImage: "cpu", tint: .green)
            settingsLabel("No account, no analytics, no tracking.",
                          systemImage: "person.crop.circle.badge.xmark", tint: .green)
            settingsLabel("Recording laws differ by region — always tell everyone in the room before recording.",
                          systemImage: "exclamationmark.bubble", tint: .orange)
        }
        .font(.callout)
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
            if let message = SummarizationService.availabilityMessage {
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
        SummarizationService.availabilityMessage == nil ? "Ready" : "Unavailable"
    }

    // MARK: - Actions

    private func deleteAllMeetings() {
        for meeting in meetings {
            MeetingStore.delete(meeting, context: context)
        }
        usage = MeetingStore.recordingsUsage()
    }

    private func refreshTranscriptionStatus() async {
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

#Preview {
    SettingsView()
        .modelContainer(for: Meeting.self, inMemory: true)
}

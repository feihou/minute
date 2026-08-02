import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Privacy explanation and on-device capability status.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var transcriptionStatus = "Checking…"

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    Label("Recordings, transcripts, and summaries stay on this iPhone.", systemImage: "iphone")
                    Label("Transcription and summarization run entirely on device.", systemImage: "cpu")
                    Label("No account, no analytics, no tracking.", systemImage: "person.crop.circle.badge.xmark")
                    Label("Deleting a meeting permanently deletes its audio and notes.", systemImage: "trash")
                }
                .font(.callout)

                Section {
                    Text("Recording laws differ by region. Always tell everyone in the room before you record a meeting.")
                        .font(.callout)
                } header: {
                    Text("Recording Consent")
                }

                Section("On-Device Capabilities") {
                    LabeledContent("Microphone", value: microphoneStatus)
                    LabeledContent("Transcription", value: transcriptionStatus)
                    LabeledContent("Summarization", value: summarizationStatus)
                    if let message = SummarizationService.availabilityMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } footer: {
                    Text("Manage microphone access and Apple Intelligence in iOS Settings.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refreshTranscriptionStatus() }
        }
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
}

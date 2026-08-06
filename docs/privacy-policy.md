# Privacy Policy for Minute

**Effective date: August 6, 2026**

Minute is an iPhone app that records in-person meetings, transcribes them live on your device, identifies speakers when you ask it to, and generates meeting notes with on-device AI. This policy explains what data the app handles and what happens to it. The short version: the developer never receives your meeting content; recordings, transcripts, and summaries stay on your iPhone unless you back up or share them, and model setup never uploads them.

Minute is open source under the MIT license. You can verify everything in this policy by reading the code at [github.com/feihou/minute](https://github.com/feihou/minute).

## What Minute is

Minute records meeting audio with your iPhone's microphone, produces a live transcript using Apple's on-device speech recognition (SpeechTranscriber, iOS 26), optionally identifies speakers using FluidAudio's on-device model, and generates structured summaries — overview, key points, decisions, action items, open questions, and, when speakers have been identified, per-speaker perspectives — using Apple's on-device Apple Intelligence model (FoundationModels). Audio analysis, transcription, speaker identification, and summary generation happen on your iPhone.

## Data the app handles

Minute creates and stores the following data **locally on your iPhone**, in its private app storage or preferences, unless you use an optional backup or sharing feature described below:

- **Audio recordings** of your meetings (created only when you start a recording)
- **Transcripts**, with timestamps and optional speaker labels, generated on-device from your recordings
- **Summaries and notes** generated on-device from your transcripts
- **Meeting metadata** — titles, dates, durations
- **Your settings** — audio quality, summary preferences, optional summary context you type in (such as attendee names or project terms)

None of this meeting content is transmitted to the developer, Hugging Face, FluidAudio, or an AI/transcription service. A model download sends routine connection metadata to the model host, as described below. Your own backup and sharing choices can also create copies outside Minute's local storage.

If you add the optional Home Screen widget, it displays recent meeting titles, dates, and durations from a small snapshot stored locally on your device. The widget contains no audio, transcripts, or notes.

## What never happens

- **No account.** You never sign up, log in, or provide an email address.
- **No backend.** Minute has no developer-operated server. Your meeting content is never uploaded to the developer, an AI service, FluidAudio, or Hugging Face.
- **No analytics or telemetry.** The app contains no analytics SDK and sends no usage data, crash reports, or diagnostics.
- **No tracking by Minute or the developer.** Minute creates no account, advertising identifier, or tracking profile and shares no data with data brokers or ad networks. The speaker-model host receives routine connection metadata under its own privacy policy, as described below.
- **No ads.**
- **No sale of data.** The developer has no user data to sell, and never will under this design.

## Model downloads

To identify different speakers in a meeting (diarization), Minute uses the open-source FluidAudio library, which runs entirely on-device. The first time this feature is prepared, FluidAudio downloads its CoreML model files (about 22 MB) from Hugging Face, a public model-hosting service. The models are then cached on your device.

**What is transmitted:** a standard HTTPS download request with no Minute account or app-generated identifier. Like any web request, it includes routine connection metadata such as your IP address and standard HTTP headers, which are visible to Hugging Face as the hosting provider (see [Hugging Face's privacy policy](https://huggingface.co/privacy)).

Hugging Face controls whether and how it retains that routine connection metadata. Minute does not receive those logs and cannot use them to identify or profile you. Review Hugging Face's current policy before using speaker identification if this connection metadata is a concern.

**What is never transmitted:** your recordings, transcripts, summaries, settings, or any other content from the app. The request contains no account information or identifiers created by Minute — the app has none. It is a file download, nothing more.

The speaker-model fetch is Minute's only request to a non-Apple endpoint. When you enable **iCloud Drive Folder**, Minute also asks Apple's iCloud APIs to mirror meeting notes and audio to your own account when the option is enabled and when the app enters the background. Separately, iOS may download Apple's on-device speech-recognition assets when transcription is prepared, and iOS manages any device backup you enable. These Apple-service paths are described next; none sends meeting content to the developer or a model provider.

## Optional iCloud features (off by default)

Minute offers two meeting-data backup options in Settings. Both are **off by default**, and both put copies only in **your own iCloud account** through Apple system services. The developer has no access to your iCloud account and cannot see, retrieve, or delete anything you back up.

1. **iCloud Backup** — includes your meeting data in your iPhone's normal device backup. It comes back only by restoring your iPhone from that backup. Handled entirely by iOS and governed by [Apple's iCloud terms and privacy policy](https://www.apple.com/legal/privacy/).
2. **iCloud Drive Folder** — mirrors a browsable folder per meeting (notes and audio) into your iCloud Drive, visible in the Files app under `iCloud Drive → Minute`. You can open, copy, or delete these files yourself at any time.

Turning either option off stops future meeting-data copies. Files already in iCloud Drive remain until you delete them in the Files app — they are your files, in your storage.

The **iCloud Backup** toggle controls Minute's meeting store, recordings, and widget snapshot. It does not currently control ordinary app preferences stored in `UserDefaults`, including Summary Context, audio quality, summary template/language, and backup choices. [Apple documents that persistent defaults are normally included in a device backup](https://developer.apple.com/documentation/foundation/userdefaults), so those preferences may be restored with your iPhone's backup even when Minute's in-app iCloud Backup toggle is off. They are not mirrored into Minute's iCloud Drive folder or sent to the developer.

## Permissions

- **Microphone.** Required to record meetings. Minute asks for permission before your first recording and records only when you explicitly start a recording. You can revoke this at any time in iOS Settings.
- **Speech recognition.** Transcription uses Apple's on-device speech framework. Audio is processed locally; it is not sent to Apple's servers for recognition.

A reminder that is your responsibility, not a data practice of the app: recording laws differ by region. Always tell everyone in the room before recording.

## Data retention and deletion

Your meeting data stays in Minute's local storage unless you back up or share it, and remains there until you delete it:

- **Deleting a meeting in the app permanently removes** its audio file, transcript, summary, and database entry from your iPhone. A cleanup pass at app launch also removes any audio files orphaned by a crash.
- **Delete All Meetings** in Settings removes all meetings and their recordings, transcripts, summaries, and speaker labels. It does not reset app preferences such as Summary Context, audio quality, template/language, or backup choices; you can edit or clear those settings separately.
- **Deleting the app** removes all of its local data, as with any iOS app.
- **iCloud copies are yours to manage.** If you enabled the iCloud Drive folder, deleting a meeting removes files Minute recognizes as its mirrored notes, audio, and markers on the next enabled sync. The folder remains when unrecognized files are present. Recognition is filename-based: a user-added audio file with a UUID-only filename can resemble a mirrored recording and be removed. Keep unrelated files outside generated meeting folders, or rename them, if they must be preserved. Files left after you turn the option off, and data inside past device backups, are under your control — delete them in the Files app or in your iCloud settings.

The developer cannot delete your data for you, because the developer never has it.

## Children's privacy

Minute does not knowingly collect personal information through the app. It has no account, ads, analytics, or developer backend, and it does not send meeting content to the developer. The App Store age rating is determined from the release owner's current App Store Connect questionnaire and is not asserted in this policy.

## Changes to this policy

If Minute's data practices ever change — for example, if a future version adds a feature that involves a new network request — this policy will be updated before that version ships, with the new effective date shown at the top. The full history of this document is available in the app's public source repository.

## Contact

Questions about privacy in Minute:

- **GitHub issues:** [https://github.com/feihou/minute/issues](https://github.com/feihou/minute/issues)

---

Copyright © 2026 Fei Hou. Minute is open-source software released under the MIT license.

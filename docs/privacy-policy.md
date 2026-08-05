# Privacy Policy for Minute

**Effective date: August 4, 2026**

Minute is an iPhone app that records in-person meetings, transcribes them live on your device, and generates meeting notes with on-device AI. This policy explains what data the app handles and what happens to it. The short version: your meetings stay on your iPhone, and the developer never sees any of your data.

Minute is open source under the MIT license. You can verify everything in this policy by reading the code at [github.com/feihou/minute](https://github.com/feihou/minute).

## What Minute is

Minute records meeting audio with your iPhone's microphone, produces a live transcript using Apple's on-device speech recognition (SpeechTranscriber, iOS 26), identifies speakers using an on-device model, and generates structured summaries — overview, key points, decisions, action items, open questions, and per-speaker perspectives — using Apple's on-device Apple Intelligence model (FoundationModels). All of this processing happens on your iPhone.

## Data the app handles

Minute creates and stores the following data, all of it **locally on your iPhone**, in the app's private storage area:

- **Audio recordings** of your meetings (created only when you start a recording)
- **Transcripts**, with timestamps and speaker labels, generated on-device from your recordings
- **Summaries and notes** generated on-device from your transcripts
- **Meeting metadata** — titles, dates, durations
- **Your settings** — audio quality, summary preferences, optional summary context you type in (such as attendee names or project terms)

None of this data is transmitted to the developer or to any third party. There is no server to send it to.

If you add the optional Home Screen widget, it displays recent meeting titles, dates, and durations from a small snapshot stored locally on your device. The widget contains no audio, transcripts, or notes.

## What never happens

- **No account.** You never sign up, log in, or provide an email address.
- **No server.** Minute has no backend. Your meeting content is never uploaded to any server operated by the developer or anyone else.
- **No analytics or telemetry.** The app contains no analytics SDK and sends no usage data, crash reports, or diagnostics.
- **No tracking.** No identifiers are collected, no profiles are built, and no data is shared with data brokers or ad networks.
- **No ads.**
- **No sale of data.** The developer has no user data to sell, and never will under this design.

## The one network request: speaker-identification model download

To identify different speakers in a meeting (diarization), Minute uses the open-source FluidAudio library, which runs entirely on-device. The first time this feature is prepared, the app downloads FluidAudio's CoreML model files (about 22 MB) from Hugging Face, a public model-hosting service. The models are then cached on your device and not downloaded again.

**What is transmitted:** a standard, anonymous HTTPS download request. Like any web request, it includes routine connection metadata such as your IP address and standard HTTP headers, which are visible to Hugging Face as the hosting provider (see [Hugging Face's privacy policy](https://huggingface.co/privacy)).

**What is never transmitted:** your recordings, transcripts, summaries, settings, or any other content from the app. The request contains no account information or identifiers created by Minute — the app has none. It is a file download, nothing more.

This is the only network request Minute itself makes. Separately, iOS may download Apple's on-device speech recognition model the first time transcription is set up; that download is performed by Apple's system software as part of iOS, not by Minute, and likewise never includes your meeting content.

## Optional iCloud features (off by default)

Minute offers two backup options in Settings. Both are **off by default**, and both send data only to **your own iCloud account** — storage that Apple provides to you and that only you control. The developer has no access to your iCloud account and cannot see, retrieve, or decrypt anything you back up.

1. **iCloud Backup** — includes your meeting data in your iPhone's normal device backup. It comes back only by restoring your iPhone from that backup. Handled entirely by iOS and governed by [Apple's iCloud terms and privacy policy](https://www.apple.com/legal/privacy/).
2. **iCloud Drive Folder** — mirrors a browsable folder per meeting (notes and audio) into your iCloud Drive, visible in the Files app under `iCloud Drive → Minute`. You can open, copy, or delete these files yourself at any time.

Turning either option off stops future copies. Files already in iCloud Drive remain until you delete them in the Files app — they are your files, in your storage.

## Permissions

- **Microphone.** Required to record meetings. Minute asks for permission before your first recording and records only when you explicitly start a recording. You can revoke this at any time in iOS Settings.
- **Speech recognition.** Transcription uses Apple's on-device speech framework. Audio is processed locally; it is not sent to Apple's servers for recognition.

A reminder that is your responsibility, not a data practice of the app: recording laws differ by region. Always tell everyone in the room before recording.

## Data retention and deletion

Your data is kept only on your device, only until you delete it:

- **Deleting a meeting in the app permanently removes** its audio file, transcript, summary, and database entry from your iPhone. A cleanup pass at app launch also removes any audio files orphaned by a crash.
- **Delete All Meetings** in Settings removes everything at once.
- **Deleting the app** removes all of its local data, as with any iOS app.
- **iCloud copies are yours to manage.** If you enabled the iCloud Drive folder, deleting a meeting in the app removes its mirrored folder on the next sync while the option is on. Files left in iCloud Drive after you turn the option off, and data inside past device backups, are under your control — delete them in the Files app or in your iCloud settings.

The developer cannot delete your data for you, because the developer never has it.

## Children's privacy

Minute does not collect personal information from anyone, including children. The app is rated 4+ on the App Store. Because there is no data collection, there is no processing of children's data to disclose.

## Changes to this policy

If Minute's data practices ever change — for example, if a future version adds a feature that involves a new network request — this policy will be updated before that version ships, with the new effective date shown at the top. The full history of this document is available in the app's public source repository.

## Contact

Questions about privacy in Minute:

- **GitHub issues:** [https://github.com/feihou/minute/issues](https://github.com/feihou/minute/issues)
- **Email:** [ADD CONTACT EMAIL HERE]

---

Copyright © 2026 Fei Hou. Minute is open-source software released under the MIT license.
# Minute

**Privacy-first meeting notes for iPhone. Process every meeting entirely on your device.**

![Platform](https://img.shields.io/badge/platform-iOS%2026%2B-blue)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SwiftData-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

Minute records in-person meetings, produces a live transcript with Apple's on-device speech models, and generates structured notes with the on-device Apple Intelligence model. Over time it also builds **Brain**, a local knowledge base of the people, projects, and topics your meetings keep returning to. **Recordings, transcripts, and summaries stay on your iPhone by default**; meeting-content copies are created only through the backup or sharing options you choose. There is no account, backend, analytics, or tracking.

| Meeting library | Recording | Meeting notes |
|:---:|:---:|:---:|
| <img src="docs/app-store/3-library.png" width="200" alt="Searchable meeting library"> | <img src="docs/app-store/1-recording.png" width="200" alt="Recording screen with a live transcript"> | <img src="docs/app-store/2-notes.png" width="200" alt="Structured on-device meeting notes"> |

## Why

Meeting audio is some of the most sensitive data on your phone. Most meeting-notes apps upload it to a server for transcription and summarization. Minute takes the opposite bet: with iOS 26, the phone itself is powerful enough to do all of it locally — so your conversations never need to leave the room.

## Features

- 🎙️ **One-tap recording** with pause/resume, background recording, and graceful handling of phone calls and AirPods switches — on any handled failure (interruption, route change, stop error) the app always offers to save the audio captured so far
- 📝 **Live on-device transcript** while you record (`SpeechAnalyzer`/`SpeechTranscriber`, iOS 26), with timestamped segments — tap a line to jump playback there
- ✨ **On-device AI notes** via Apple's FoundationModels: overview, key points, decisions, action items (owner/deadline are `Not specified` unless actually said), and open questions. Choose from five meeting templates, set an output language, add spelling/background context, and optionally summarize automatically after saving
- 🔀 **Choose your engines**: transcription runs on Apple Speech or, optionally, a [WhisperKit](https://github.com/argmaxinc/WhisperKit) model you download in Settings (auto-detects the spoken language); notes run on Apple Intelligence or, optionally, a local open model via MLX. Both alternatives download once from Hugging Face, then run entirely offline
- 📚 **Long-meeting support**: transcripts are chunked, noted per chunk, and merged, staying inside the model's 4,096-token context window — including for dense-token languages like Chinese and Japanese
- 👥 **Optional speaker identification** over saved audio with FluidAudio's on-device diarization model; rename speaker labels and generate per-speaker perspectives. The model downloads once from Hugging Face when first used, then stays cached; meeting audio is never uploaded
- 📥 **Audio import and re-transcription**: bring in an existing audio file, transcribe it locally when Apple Speech is available, or replace a saved meeting's transcript later
- 🔎 **Search** across titles, transcript text, summaries, template sections, and speaker names
- 🧠 **Brain — a knowledge base that builds itself**: as meetings accumulate, on-device extraction collects the people, projects, and topics you keep talking about into browsable entity pages, each with an AI-written synthesis over dated facts that link back to the meeting they came from. Opening a meeting shows a *What You Know* brief for participants Minute already recognizes. Built in the background while the app is open, entirely on device; currently read-only
- ▶️ **Playback** with scrubbing; edit the title and structured summary; copy or share plain-text/Markdown notes (including the transcript when available). Transcript text is read-only, while identified speaker names can be edited
- 🗑️ **Real deletion**: deleting a meeting deletes its audio file and notes from disk, plus the Brain facts it produced — an entity left with nothing to show is removed with them, and any entity that keeps other facts has its written summary regenerated so it can't still describe the deleted meeting. A startup sweep clears audio orphaned by a crash and facts orphaned by any deletion that didn't finish
- ☁️ **Opt-in iCloud backup**: include meeting data in the iPhone's device backup, and/or mirror a browsable folder per meeting (notes + audio) into iCloud Drive — both off by default
- 🏠 **Optional Home Screen widget** in small or medium sizes: provides a New Meeting / recording handoff that opens the app for title and consent before recording, plus links to recent meetings. Its local App Group snapshot contains only a meeting title, date, and duration, and is visible whenever you install the widget.
- 🔴 **Recording Live Activity** on the Lock Screen and Dynamic Island, reflecting recording and pause state without controlling the recording itself
- ♿ System-native UI built on SwiftUI and iOS 26's Liquid Glass, with no UI-kit dependency: notes and entity pages are laid out as reading surfaces rather than stacked cards, and glass is reserved for the floating layer (toolbars, the New Meeting bar, status pills). Light/dark mode, Dynamic Type through the accessibility sizes, and VoiceOver labels throughout

## Privacy guarantees

| Guarantee | How |
|---|---|
| Audio, transcripts, summaries stay on device by default | Stored in the app sandbox (Application Support + SwiftData), excluded from iCloud/computer device backups by default; opt-in Settings toggles can include them in the iPhone's device backup (**iCloud Backup**) or mirror a browsable per-meeting folder into iCloud Drive (**iCloud Drive Folder**, under `Minute/<this device>/`); turning a toggle back off stops future copies but leaves existing iCloud copies for you to manage — **meeting content is never sent to the developer or a model service** |
| No account, analytics, or tracking | There is no backend or telemetry SDK. The third-party packages are all on-device model runtimes — FluidAudio (speaker identification), WhisperKit (optional transcription), and MLX (optional local summaries) — never clients for a service that sees your meetings |
| Transcription is local | Apple `SpeechTranscriber` with on-device model assets, or an optional WhisperKit model running offline after download |
| Summarization is local | Apple `FoundationModels` (Apple Intelligence on-device model), or an optional local model run through MLX |
| The knowledge base is local | Entities and facts are extracted by the same on-device model and stored in the app's SwiftData store; nothing about them is uploaded |
| Speaker identification is local after setup | FluidAudio's CoreML models download from Hugging Face when first used and are then cached; the request does not include recordings, transcripts, or other meeting content |
| Delete means delete | Removing a meeting removes its saved audio file, its database row, and the Brain facts extracted from it — including any entity left with nothing else to say, since its name was learned from that meeting too. A fact a surviving meeting also states is re-pointed at that meeting rather than dropped. Orphaned audio and orphaned facts are both swept at launch |

> Network activity is limited to model setup and user-chosen iCloud features: iOS may fetch Apple's on-device speech assets, FluidAudio fetches its speaker-identification models from Hugging Face when you first use that feature, and any Whisper or local summary model you pick in Settings is downloaded from Hugging Face when you tap Get. None of these paths uploads recordings, transcripts, summaries, or other meeting content — they are file downloads.

### Where the two backup options put your data

| | **iCloud Backup** | **iCloud Drive Folder** |
|---|---|---|
| Where it lands | Inside the iPhone's device backup blob — not browsable | `Files → iCloud Drive → Minute → <your iPhone>/<date> <title>/` |
| What you see | Nothing in Files; the app appears in Settings → iCloud → iCloud Backup with its size | One folder per meeting containing `notes.md` and the audio file (plus a hidden `.minute-<id>` marker the sync uses to recognize its own folders) |
| When it updates | On iOS's normal device-backup schedule | When you enable it, and again when the app enters the background |
| Getting data back | Only by restoring the whole iPhone from that backup | Open or copy any file directly, on iPhone or Mac |

Each device mirrors into its own subfolder, so two iPhones on one Apple ID never overwrite each other. Deleting a meeting removes files Minute recognizes as its mirrored notes, audio, and markers on the next enabled sync. The folder remains when other, unrecognized files are present. During every enabled mirror sync, Minute also removes supported audio files whose UUID-only names look like its own but do not match the meeting's current recording. Keep extra files outside these generated meeting folders—or avoid UUID-only audio filenames—because such files can be removed even while the meeting still exists. Files left after you turn the toggle off are yours to manage in Files.

## Requirements

- **Xcode 26+** (built against the iOS 26.5 SDK), **iOS 26.0+**
- **Live transcription** needs a physical iPhone — `SpeechTranscriber` is unavailable on simulators (the app degrades gracefully and recording still works)
- Live transcription also depends on Apple Speech support for the current device language and on the on-device model being ready
- **Summaries** need an Apple Intelligence–capable iPhone with Apple Intelligence turned on (in the simulator, summaries work if the host Mac has Apple Intelligence enabled)
- Xcode resolves the pinned Swift packages automatically. All of them are on-device model runtimes for optional features; none is a network client for meeting content:

  | Package | Version | Used for |
  |---|---|---|
  | [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Offline speaker identification |
  | [WhisperKit](https://github.com/argmaxinc/WhisperKit) | 1.0.0 | Optional Whisper transcription engine |
  | [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.31.4 | Optional local summary model |
  | [swift-huggingface](https://github.com/huggingface/swift-huggingface) | 0.9.0 | Model downloads for the two options above |
  | [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.3.3 | Tokenizer support for the local summary model |
- **Production device builds** use the `iCloud.com.minuteapp.Minute` container and an App Group for the optional Home Screen widget, so physical-device builds need a paid Apple Developer team with matching iCloud/App Group provisioning. Other signing teams must either replace those container/group references with identifiers they own, or remove `Minute/Minute.entitlements`, the widget/App Group entitlements, `CODE_SIGN_ENTITLEMENTS`, and the matching `NSUbiquitousContainers` entry locally; simulator builds and CI are unaffected.

## Getting started

```bash
git clone https://github.com/feihou/minute.git
cd minute
open Minute.xcodeproj
```

Xcode resolves FluidAudio automatically. Select your team under **Signing & Capabilities**, pick your iPhone, and run. The first recording asks for microphone permission and may download the on-device speech model; speaker identification downloads its separate model only when you use that feature.

Run the tests. This example uses an iPhone 17 Pro simulator; substitute any installed iPhone listed by `xcrun simctl list devices available`:

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The suite includes a live Apple Intelligence integration test that exercises the real on-device model; it skips itself automatically on machines where the model is unavailable.

### Add the Home Screen widget

1. Long-press the Home Screen, then choose **Edit → Add Widget**.
2. Search for **Minute**.
3. Select the small or medium size, then add it.

The small widget provides one New Meeting / recording handoff that opens the app for title and consent before recording. The medium widget also separates **New Meeting** from recent-meeting links.

## Architecture

SwiftUI + SwiftData with small, single-purpose services. Apple frameworks handle recording, transcription, persistence, summaries, widgets, and Live Activities; FluidAudio is isolated to optional speaker identification:

```
Minute/
├── App/            MinuteApp — SwiftData container (with surfaced fallback)
├── Models/         Meeting (@Model), TranscriptSegment, MeetingSummary,
│                   SummaryTemplate, KnowledgeEntity, KnowledgeFact
├── Recording/      RecordingSession — orchestrates one recording end to end
├── Services/
│   ├── AudioRecorder               AVAudioEngine → AAC file + live buffer feed
│   ├── TranscriptionService        SpeechAnalyzer/SpeechTranscriber wrapper
│   ├── WhisperTranscriptionService optional WhisperKit engine
│   ├── DiarizationService          FluidAudio speaker identification over saved audio
│   ├── SummarizationService        FoundationModels + chunk/merge pipeline
│   ├── MLXSummarizationService     optional local-model summary engine
│   ├── MeetingJobs                 persistent summary/re-transcription/diarization job owner
│   ├── KnowledgeExtractionService  entities + facts from a finished meeting
│   ├── KnowledgeSynthesisService   per-entity narrative over settled facts
│   ├── KnowledgeIngest             dedupe/merge of extracted facts into the store
│   ├── KnowledgeCatchUp            background backfill loop over un-read meetings
│   ├── AudioImporter               local copy + best-effort on-device transcription
│   ├── AudioPlayerController       AVAudioPlayer playback
│   ├── MeetingStore                files on disk, delete cascade, orphan sweep
│   ├── ICloudDriveBackup           opt-in per-device notes/audio mirror
│   ├── Whisper/MLXDownloadCenter   optional model downloads and their cache
│   └── WidgetSnapshotPublisher     bounded Home Screen metadata snapshots
├── Support/        chunker, exporter, knowledge text/brief, buffer conversion, formatting
└── Views/          meetings list, recording, meeting detail, Brain + entity pages,
                    summary editor, playback, model pickers, settings
MinuteWidgets/      Home Screen widget + recording Live Activity extension
Shared/             deep links, widget snapshots, Live Activity attributes,
                    theme + reading-surface layout primitives
```

The flow: `RecordingSession` starts the recorder immediately (audio capture never waits on an optional model), then attaches transcription asynchronously once the speech model is ready. On stop, the transcript is finalized and the meeting is saved first. `MeetingJobs` then owns optional post-save work: manual or automatic summary generation, re-transcription, and speaker identification. Whenever that work changes a meeting's content, `KnowledgeCatchUp` is nudged to extract entities and facts from anything it has not read yet — foreground-only, one meeting at a time, so the knowledge base fills in without competing with the work the user is waiting on.

**AI grounding**: the model is *instructed* to use only information present in the transcript and to leave owner/deadline as the literal `"Not specified"` when unstated; post-processing in `SummarizationService` normalizes placeholders and deduplicates, but it cannot fact-check the model's output against the transcript. Like any LLM output, review a summary before acting on it. Output is structured via `@Generable`, not parsed from prose.

## Roadmap / known limitations

Contributions welcome on any of these — see [CONTRIBUTING.md](CONTRIBUTING.md):

- [ ] Improve diarization accuracy and speaker-correction UX; evaluate an Apple-native replacement if Apple exposes one
- [ ] Structured per-field editor for action items (currently `task | owner | deadline` lines)
- [ ] Handling of media-services resets during very long recordings (rare; currently pauses safely)
- [ ] Crash recovery for in-progress recordings — today, audio from a recording interrupted by an app crash is removed by the orphan sweep at next launch rather than recovered
- [ ] Knowledge-base curation — reviewing, merging, and forgetting individual entities and facts (the Brain tab is read-only today), and a chat surface grounded in it. Deleting the source meeting is currently the only way to remove something the Brain learned
- [ ] Localization of the UI (transcription already follows the device locale)
- [ ] Export formats beyond plain text/Markdown (PDF, calendar follow-ups)
- [ ] Broaden UI coverage for import, search, deep links, backup settings, and meeting-job failure paths

## Contributing

Bug reports, feature ideas, and PRs are all welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) — it covers setup, simulator caveats, testing, and the privacy invariants every change must keep (short version: **meeting content stays private, no telemetry, everything deletable, and new network/dependency behavior requires review**).

## License

[MIT](LICENSE)

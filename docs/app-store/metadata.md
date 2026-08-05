# Minute v1.0 — App Store Product Page Copy

Grounded in /Users/feihou/workplace/minute/.claude/worktrees/app-ui-settings-redesign-db71a8/README.md and /Users/feihou/workplace/minute/.claude/worktrees/app-ui-settings-redesign-db71a8/Minute/Views/SettingsView.swift. Verified: recording + live transcription work on any iPhone running iOS 26 (README states transcription needs a physical iPhone only vs. simulator — no special hardware); summaries require an Apple-Intelligence-capable iPhone. Network traffic disclosed honestly (Apple speech model fetched by iOS + one-time ~22 MB FluidAudio speaker model) — no "no network access" claim anywhere.

## 1. App Name (max 30)

1. "Minute — AI Meeting Notes" — 25 chars (recommended)
2. "Minute: Private Meeting Notes" — 29 chars
3. "Minute — On-Device Meeting AI" — 29 chars

## 2. Subtitle (max 30)

1. "Private, on-device AI notes" — 27 chars (recommended)
2. "On-device transcripts & notes" — 29 chars
3. "Meetings stay on your iPhone" — 28 chars

## 3. Promotional Text (max 170)

Option A — 164 chars:
"Meeting notes that never leave your iPhone. Record, transcribe live, and get AI summaries — all on device. No account, no server, no tracking. Free and open source."

Option B — 159 chars:
"Stop uploading your meetings. Minute records, transcribes, and summarizes entirely on your iPhone — speaker ID, decisions, action items. Open source under MIT."

## 4. Description (2,201 chars of 4,000)

Minute takes notes at your meetings so you can be in them. Record any in-person conversation, watch the transcript appear live, and get structured notes — all processed on your iPhone. No account. No server. No analytics. Your conversations never leave the room.

WHAT YOU GET

• One-tap recording — pause, resume, and keep recording in the background. Phone calls and AirPods switches are handled gracefully, and the audio captured so far is always offered for saving.

• Live transcription — Apple's on-device speech engine turns talk into timestamped text while you record. Tap any line to jump playback to that moment.

• Speaker identification — see who said what, powered by on-device speaker recognition.

• AI meeting notes — Apple Intelligence writes an overview, key points, decisions, action items, open questions, and per-speaker perspectives, entirely on device. Long meetings are chunked and merged automatically.

• Playback and editing — scrub the recording, edit titles and summaries, copy or share everything.

• Widget and Live Activity — start a meeting from your Home Screen and follow the recording from the Lock Screen.

PRIVATE BY DESIGN

Recordings, transcripts, and notes stay on your iPhone unless you decide otherwise. Two optional backups — including meetings in your iCloud device backup, or mirroring a browsable iCloud Drive folder with each meeting's notes and audio — are both off by default. Deleting a meeting deletes its audio and notes from disk. The only network traffic in the app's lifetime is a one-time download of the on-device models themselves: Apple's speech model, fetched by iOS, and a small (~22 MB) speaker model. Your recordings, transcripts, and notes are never part of any upload.

REQUIREMENTS

• iOS 26 or later. iPhone only.
• Recording and live transcription work on any iPhone running iOS 26.
• AI summaries require an Apple Intelligence–capable iPhone with Apple Intelligence turned on.

OPEN SOURCE

Minute is open source under the MIT license. Read every line at github.com/feihou/minute — there is no server, no analytics SDK, and no tracking to find.

Recording laws differ by region — always tell everyone in the room before you record.

## 5. Keywords (max 100)

"transcribe,recorder,voice,memo,summary,private,offline,transcript,speech,interview,standup,scribe" — 97 chars

No word repeats the recommended app name (Minute/AI/Meeting/Notes); "meeting" and "notes" are already indexed from the name, "minutes" via the name stem. No spaces after commas.

## 6. What's New — 1.0 (335 chars)

Welcome to Minute 1.0 — meeting notes that stay on your iPhone.

• One-tap recording with live on-device transcription
• Speaker identification
• On-device AI notes: overview, key points, decisions, action items, open questions
• Optional iCloud backup and browsable iCloud Drive folder
• Home Screen widget and recording Live Activity

## Notes for the caller

- The README's roadmap still lists diarization as pending; the copy follows the task brief and SettingsView (Speaker Model: FluidAudio row), which confirm speaker ID ships. If diarization is NOT in the 1.0 binary, drop the "Speaker identification" bullet, the "per-speaker perspectives" phrase, the ~22 MB speaker-model sentence, and the speaker line in What's New before submitting.
- Description uses plain text only: unicode bullets and CAPS section leads, no markdown.
- "Free and open source" in Promo A assumes a free listing; remove "Free and" if the app is paid.

---

# App Store Connect Compliance Answers — Minute v1.0

## 1. App Privacy questionnaire (Privacy Nutrition Label)

**Top-level question: "Do you or your third-party partners collect data from this app?" → Answer: No.**

Resulting label: **"Data Not Collected."**

Why "No" is defensible under Apple's definition: Apple defines "collect" as transmitting data off the device in a way that is accessible to you (the developer) or your third-party partners for longer than necessary to service the transmitted request. Minute fails that definition on every count:

- **User's own iCloud is not collection.** The opt-in iCloud device backup and opt-in iCloud Drive folder mirror put data into the *user's own* iCloud account via Apple system frameworks. The developer has no server, no account system, and no access to any of it. Apple's guidance explicitly excludes data stored where only the user can access it.
- **The model download is transient request servicing.** The only network request the app itself makes is a one-time, anonymous HTTPS download of FluidAudio's CoreML speaker-identification models (~22 MB) from Hugging Face. No user data, identifiers, recordings, or content are sent — only the standard connection metadata (IP address) any HTTPS request carries, used transiently to serve the file and not retained by or accessible to the developer. That falls squarely under Apple's "data used only to service a request and not retained" exclusion. (Apple's own speech-model assets are downloaded by iOS itself via AssetInventory — Apple system infrastructure, not the app.)

Walk-through of data types a reviewer or user might wonder about — all **Not Collected**:

| Data type | Reality | Label answer |
|---|---|---|
| Audio Data (User Content) | Recordings are written to the app sandbox, never transmitted. Deleting a meeting deletes the file. | Not Collected |
| Other User Content (transcripts, summaries, notes, "summary context" text) | Generated and stored on device only; optional copies go solely to the user's own iCloud. | Not Collected |
| Contact Info / Name / Email | No account, no sign-in, no forms. | Not Collected |
| Identifiers (User ID / Device ID) | None generated, none transmitted. | Not Collected |
| Usage Data / Product Interaction | No analytics or telemetry SDK of any kind. | Not Collected |
| Diagnostics / Crash Data | No crash-reporting SDK. (Opt-in crash logs users share with Apple are Apple's collection, not yours — Apple says not to declare those.) | Not Collected |
| Location, Contacts, Health, Financial, Browsing/Search History, Photos | Never accessed. | Not Collected |

**Tracking question ("Is this data used to track users?")**: No data types are collected, so tracking is automatically No. No AppTrackingTransparency prompt exists or is needed.

**Third-party partners check**: FluidAudio is a library whose static model files are fetched from a CDN (Hugging Face); neither is a "partner collecting data from this app." No SDK in the binary phones home.

## 2. Age rating questionnaire

Expected answers — every content question is **None / No**:

| Question area | Answer |
|---|---|
| Cartoon/fantasy/realistic violence | None |
| Profanity or crude humor | None |
| Mature/suggestive themes, sexual content, nudity | None |
| Horror/fear themes | None |
| Medical/treatment information | None |
| Alcohol, tobacco, drug use or references | None |
| Simulated gambling / real gambling | None / No |
| Contests | No |
| Unrestricted web access | No (the only web touchpoint is a fixed model-file download; no browser) |
| User-generated content shared with others / social features / messaging | No (users' notes are private to their device; nothing is shared to other users) |
| App-provided or third-party advertising | No |
| Parental controls / age assurance | No |

**Resulting rating: 4+** (regional equivalents are derived automatically).

## 3. App Review notes (ready to paste)

> Minute records in-person meetings and processes everything on the device: live transcription uses Apple's on-device SpeechTranscriber (iOS 26), and meeting notes (overview, key points, decisions, action items, open questions, speaker perspectives) are generated by Apple's on-device FoundationModels (Apple Intelligence). There is no account, no login, and no server — no demo credentials are needed. To test: launch the app, tap the record button (a microphone permission prompt appears on first recording — please allow), speak a few sentences, tap stop, and open the meeting to see the transcript; then generate notes from the meeting detail screen. Network usage: the app itself makes exactly one kind of network request — a one-time, anonymous download (~22 MB) of the FluidAudio speaker-identification CoreML models from Hugging Face when speaker identification is first used; iOS may also download Apple's own on-device speech model on first recording via Apple system infrastructure. No user content or identifiers are ever transmitted. AI note generation requires an Apple-Intelligence-capable iPhone with Apple Intelligence enabled and its model downloaded; on other devices the app shows a clear "summarization unavailable" message (visible in Settings > On-Device Capabilities) while recording, playback, and live transcription continue to work — this message is expected behavior, not a bug. Optional features: a Home Screen widget and a recording Live Activity; opt-in (off by default) iCloud backup options that copy data only to the user's own iCloud. The app is open source (MIT): https://github.com/feihou/minute

## 4. Export compliance

Confirmed in the repo: `ITSAppUsesNonExemptEncryption` is set to `false` in `Minute/Info.plist` (lines 5–6). With that key present, App Store Connect skips the export-compliance questions on every build upload.

If asked anyway (e.g., in the submission UI):
- "Does your app use encryption?" → **Yes** (HTTPS/TLS via ATS for the model download, plus OS-provided data protection and iCloud transport).
- "Does your app qualify for any of the exemptions in Category 5, Part 2 of the EAR?" → **Yes** — the app uses only the standard encryption built into Apple's operating system; it implements no proprietary or non-standard cryptography. No CCATS or France declaration is needed for this classification.

## 5. Category recommendation

**Primary: Productivity. Secondary: Business.**

Productivity should be primary: Minute is a personal note-taking/meeting-notes tool in the same shelf as transcription and notes apps that live in Productivity, and the category matches the app's core loop (capture → transcript → actionable notes for one user). The Business category skews toward enterprise/team tooling (CRM, collaboration suites) and implies an organizational buyer Minute doesn't have — no accounts, no teams. Business as secondary still captures "meeting" search intent.

## 6. Copyright line

App Store Connect copyright field (per Apple's format — year + rights owner, no URL, © is added by the store):

**`2026 Fei Hou`**

(If a literal line is wanted elsewhere: `© 2026 Fei Hou`.)

## 7. Support URL and Marketing URL

- **Support URL (required):** `https://github.com/feihou/minute/issues` — a GitHub Issues page is acceptable to App Review as a support URL: it is reachable, current, and gives users a working way to contact the developer.
- **Marketing URL (optional):** `https://github.com/feihou/minute` — the README already functions as a product page (positioning, screenshots, privacy guarantees). Leave blank or upgrade to a GitHub Pages site later; it can be changed anytime without a new build.

## 8. Pricing (free app)

Nothing special — confirmed:
- Set price to **Free (Tier 0)**; choose territories.
- No in-app purchases and no subscriptions, so the **Paid Applications Agreement is not required** — the standard free Apple Developer Program License Agreement covers it.
- Free + no IAP also means no additional tax/banking setup is needed in App Store Connect, and none of the age-rating or privacy answers above change.

---
Sources verified: `/Users/feihou/workplace/minute/.claude/worktrees/app-ui-settings-redesign-db71a8/README.md`, `/Users/feihou/workplace/minute/.claude/worktrees/app-ui-settings-redesign-db71a8/Minute/Views/SettingsView.swift` (in-app privacy copy, including the FluidAudio/Hugging Face disclosure), `/Users/feihou/workplace/minute/.claude/worktrees/app-ui-settings-redesign-db71a8/Minute/Info.plist` (export-compliance key).
# Minute v1.0 — App Store Product Page and Compliance Draft

**Verified against the repository and official Apple guidance: August 6, 2026.**

Repository sources: `README.md`, `docs/privacy-policy.md`, `Minute/Views/SettingsView.swift`, `Minute/Views/MeetingDetailView.swift`, `Minute/Services/TranscriptionService.swift`, `Minute/Services/DiarizationService.swift`, `Minute/Info.plist`, `Minute/PrivacyInfo.xcprivacy`, `MinuteWidgets/PrivacyInfo.xcprivacy`, and `Minute.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

This is a release-owner draft, not legal advice. Product copy below is ready to paste after the release checks; privacy, export, rating, pricing, and support fields remain the App Store Connect account holder's responsibility.

## Product page copy

### 1. App Name (25 of 30 characters)

`Minute — AI Meeting Notes`

### 2. Subtitle (27 of 30 characters)

`Private, on-device AI notes`

### 3. Promotional Text (134 of 170 characters)

`Record, transcribe, identify speakers, and create AI notes on your iPhone. No account, no backend, no tracking. Open source under MIT.`

### 4. Description (2,895 of 4,000 characters)

Minute takes notes at your meetings so you can be in them. Record an in-person conversation, watch the transcript appear live, and create structured notes — all processed on your iPhone. No account. No backend. No analytics. Meeting content is not uploaded to an AI or transcription service.

WHAT YOU GET

• One-tap recording — pause, resume, and keep recording in the background. Phone calls and audio-route changes are handled gracefully, and recoverable failures offer to save the audio captured so far.

• Live transcription — Apple's on-device speech engine turns speech into timestamped text while you record. Tap a line to jump playback to that moment. Availability depends on Apple Speech support for your iPhone's current language and on the local model being ready.

• Speaker identification — after a meeting, optionally identify and rename speakers with FluidAudio's on-device model. The model downloads from Hugging Face when first used; recordings are never part of that request.

• AI meeting notes — Apple Intelligence creates an overview, key points, decisions, action items, and open questions entirely on device. Choose a meeting template and output language, add spelling context, and get per-speaker perspectives after speakers have been identified. Long meetings are chunked and merged automatically.

• Import, search, and revisit — import existing audio for best-effort local transcription; search titles, transcripts, notes, and speaker names; re-transcribe saved audio when needed.

• Playback and editing — scrub recordings, edit titles and summaries, rename speakers, and copy or share plain-text notes with the transcript included.

• Widget and Live Activity — start a meeting from the Home Screen, open recent meetings from the medium widget, and follow recording state from the Lock Screen or Dynamic Island.

PRIVATE BY DESIGN

Recordings, transcripts, and summaries stay on your iPhone by default. Two optional meeting-data backups — including them in your iPhone backup, or mirroring browsable notes and audio to iCloud Drive — are both off by default. Deleting a meeting removes its local recording and notes. Network activity is limited to model setup and user-chosen iCloud features: iOS may fetch Apple's speech assets, and FluidAudio fetches its speaker model from Hugging Face. Meeting content is never uploaded to either model host.

REQUIREMENTS

• iOS 26 or later. iPhone only.
• Recording works without transcription. Live transcription requires Apple Speech support for the current device language and model availability.
• AI notes require an Apple Intelligence-capable iPhone with Apple Intelligence enabled.

OPEN SOURCE

Minute is open source under the MIT License. Read the code at github.com/feihou/minute — there is no backend, analytics SDK, or tracking.

Recording laws differ by region. Always tell everyone in the room before you record.

### 5. Keywords (97 of 100 bytes)

`transcribe,recorder,voice,memo,summary,private,offline,transcript,speech,interview,standup,scribe`

The list does not repeat words from the recommended app name. App Store Connect measures this field in bytes, not characters.

### 6. What's New

App Store Connect does not show a What's New field for an app's first version. For the first update, adapt this copy to the changes that actually ship:

Minute brings private meeting notes to your iPhone:

• One-tap recording with live on-device transcription
• Optional speaker identification and renameable labels
• On-device AI notes with templates, action items, and open questions
• Audio import, search, playback, and re-transcription
• Optional iCloud backup and browsable iCloud Drive folder
• Home Screen widget and recording Live Activity

## Release checks before pasting product copy

- Confirm the App Store price before adding any pricing language; the product copy above makes no free/paid claim.
- Test live transcription for the release device languages. Recording still works when transcription is unavailable or its model is not ready.
- Confirm the archived app still contains FluidAudio 0.15.5 and inspect the archive's privacy report before upload.
- Verify the FluidAudio model size/host and the model host's request-data retention practices for the exact release dependency. The copy intentionally does not promise that connection metadata is never retained.
- Speaker perspectives are conditional: they appear only after the transcript has speaker labels.
- Imported audio can be saved without a transcript when Apple Speech is unavailable or transcription fails.
- Summary Context and other `UserDefaults` preferences can participate in the user's normal device backup independently of Minute's in-app meeting-data backup toggle; the privacy policy discloses this current limitation.
- Visually inspect the three numbered screenshots in `docs/app-store/` at release time. A fourth privacy screenshot is intentionally withheld: the current Settings UI says Summary Context “Stays on device,” while ordinary `UserDefaults` can participate in device backup. Add a replacement only after the UI/storage behavior is corrected or the inaccurate helper is outside the captured frame.
- **Release blocker:** add an easily accessible Privacy Policy link inside the app. The current Settings screen has no policy link, while Apple's App Review Guidelines require one in both App Store Connect metadata and the app.

---

# App Store Connect Compliance Draft

## 1. App Privacy questionnaire

**Candidate top-level answer:** `No, we do not collect data from this app.`

Do not submit that answer until the release owner verifies the current FluidAudio/Hugging Face request behavior. Apple defines collection as transmitting data off-device so the developer or a third-party partner can access it for longer than needed to service the request in real time. An IP address or similar request data does not need disclosure only when it is not retained beyond servicing the request. See [Apple's App Privacy details](https://developer.apple.com/app-store/app-privacy-details/).

Repository-backed reasoning:

- **Meeting processing is on device.** Recordings, transcripts, speaker assignments, summaries, settings, and searches are processed locally. On-device-only processing is not collection.
- **The developer has no backend access.** The code contains no account, analytics, advertising, telemetry, or crash-reporting service.
- **User-controlled iCloud uses Apple services.** The optional device-backup and iCloud Drive paths copy data only to the user's Apple account; the developer has no retrieval path. Apple's guidance says developers are not responsible for disclosing data Apple collects through Apple frameworks and services. This supports the candidate answer, but Apple does not publish the broader phrase “the user's own iCloud is never collection.”
- **The speaker-model request is conditional.** The candidate `No` answer depends on Hugging Face/FluidAudio not retaining accessible request data beyond real-time request servicing and on the dependency adding no telemetry. Re-check the exact release version.
- **Persistent preferences may be backed up.** Summary Context and other `UserDefaults` values can be included in the user's device backup. That is an Apple backup path, not developer access, and it is disclosed in the privacy policy.

Data-type audit, assuming the candidate answer remains valid:

| Data type | Repository behavior | Candidate label answer |
|---|---|---|
| Audio Data (User Content) | Recordings remain in the app sandbox unless the user backs up or shares them; no model service receives them. | Not Collected |
| Other User Content | Transcripts, summaries, speaker names, and Summary Context are processed locally; user-chosen copies use Apple backup/share services. | Not Collected |
| Contact Info | No account, sign-in, or contact form in the app. | Not Collected |
| Identifiers | Minute creates no account/user/device advertising identifier for transmission. | Not Collected |
| Usage Data | No analytics or telemetry code. | Not Collected |
| Diagnostics | No app-integrated crash-reporting service. | Not Collected |
| Location, Contacts, Health, Financial, Photos, Browsing History | Not accessed by app code. | Not Collected |

**Tracking:** Candidate answer `No`; the privacy manifests set `NSPrivacyTracking` to `false` and declare no tracking domains.

**Third-party review:** FluidAudio is third-party code and Hugging Face is an external vendor for the model fetch. Review both under Apple's third-party-partner definition; package identity alone does not decide the App Privacy answer.

**Privacy manifests:** FluidAudio is not currently named on Apple's [commonly used third-party SDK list](https://developer.apple.com/support/third-party-SDK-requirements/), so the special listed-SDK signature/manifest rule does not apply by name. The app must still cover required-reason APIs used by its own code or dependencies. `Minute/PrivacyInfo.xcprivacy` declares UserDefaults and file-timestamp access; the widget manifest declares its App Group UserDefaults access. Confirm the combined archive privacy report before submission.

## 2. Age rating questionnaire

Expected questionnaire posture, subject to the release binary and App Store Connect's resulting rating:

| Question area | Expected answer | Basis |
|---|---|---|
| Violence, profanity, mature/suggestive themes, sexual content, horror, medical, substance use, gambling | None | Minute supplies no catalog of such content. |
| User-Generated Content | No | Apple defines this category around broad distribution of user-created content; Minute keeps private recordings/notes for the same user and has no social distribution feature. |
| Unrestricted Web Access | No | Users cannot browse the web; a fixed model-download endpoint is not unrestricted browsing under Apple's definition. |
| Advertising | No | No advertising code or inventory. |
| Messaging/social features | No | No accounts, shared feed, messaging, or in-app user-to-user delivery. |
| Parental controls / age assurance | No | No such feature. |

Use App Store Connect's generated rating as the source of truth; do not hard-code a `4+` outcome in release notes before completing the current questionnaire.

Official definitions: [Age rating values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/).

## 3. App Review notes (ready to paste)

> Minute records in-person meetings and processes meeting content on the device. Live transcription uses Apple's on-device SpeechTranscriber (iOS 26). Structured notes use Apple's on-device FoundationModels and require Apple Intelligence. Optional speaker identification uses FluidAudio's offline CoreML pipeline; the model files are downloaded from Hugging Face when first used and cached, but recordings, transcripts, summaries, and identifiers created by Minute are not part of that request. There is no account, login, backend, analytics, or demo credential. To test: launch the app, tap the record button, allow microphone access, speak a few sentences, stop, and open the saved meeting. Transcription depends on Apple Speech support for the device language and local model readiness; recording and playback continue when it is unavailable. Generate notes from the meeting detail screen. Speaker identification is a separate optional action on a saved meeting and may need network access for its first model setup. Optional iCloud Backup and iCloud Drive Folder features are both off by default and copy meeting data only to the reviewer's own iCloud account. The project is open source under the MIT License: https://github.com/feihou/minute

## 4. Export compliance

Repository fact: `ITSAppUsesNonExemptEncryption` is `false` in `Minute/Info.plist`.

That key does **not** mean the app uses no encryption. It represents the developer's determination that the app does not use non-exempt encryption requiring App Store Connect documentation. The current code relies on encryption provided by Apple's operating system for HTTPS, device data protection, and iCloud; it implements no proprietary cryptography.

Apple's current reference says apps whose encryption is limited to the Apple operating system require no export-compliance documentation in App Store Connect. The release owner must still confirm that classification for the final binary and distribution territories. See [Apple's export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) and [documentation matrix](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/).

## 5. Category recommendation

**Primary:** Productivity

**Secondary:** Business

Productivity matches the core personal workflow: capture, transcript, search, and actionable notes. Business remains a useful secondary category without implying accounts, teams, CRM, or enterprise administration.

## 6. Copyright

App Store Connect field: `2026 Fei Hou`

Apple adds the copyright symbol automatically.

## 7. Support, marketing, and privacy URLs

- **Support URL — release blocker:** `https://github.com/feihou/minute/issues` alone is not enough under Apple's written requirement. Apple says the Support URL must lead to actual contact information such as a legal address, email address, or telephone number. Publish a stable support page containing the required contact information, then use that page's full HTTPS URL. See [Apple's platform version information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).
- **Marketing URL (optional):** `https://github.com/feihou/minute`
- **Privacy Policy URL (required):** publish `docs/privacy-policy.md` at a stable public HTTPS URL before submission. A raw repository path is source material, not a guaranteed product-facing policy URL.
- **Privacy Choices URL (optional):** a published privacy/help page can explain local deletion, clearing Summary Context, iCloud Drive cleanup, and device-backup management.

## 8. Pricing and agreements

Pricing is an App Store Connect release decision, not a repository fact. If the account holder chooses **Free** and the app has no in-app purchases or subscriptions, confirm the current agreement, banking, tax, and territory requirements directly in App Store Connect before release. Do not carry a pricing assumption from this document into promotional copy.

## Official Apple sources checked

- [App information limits (name and subtitle)](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)
- [Platform version fields (promotional text, description, keywords, support URL, What's New)](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [App Review Guidelines (privacy policy availability)](https://developer.apple.com/app-store/review/guidelines/)
- [App Privacy details and transient request-servicing exclusion](https://developer.apple.com/app-store/app-privacy-details/)
- [Third-party SDK privacy requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
- [Age rating values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)
- [Export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [Export compliance documentation matrix](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
- [UserDefaults backup behavior](https://developer.apple.com/documentation/foundation/userdefaults)

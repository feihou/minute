# Contributing to Minute

Thanks for helping build a meeting-notes app that respects privacy. This guide gets you productive quickly and explains the few hard rules.

## Setup

1. Install **Xcode 26+** (the project builds against the iOS 26.5 SDK).
2. Clone and open:
   ```bash
   git clone https://github.com/feihou/minute.git
   cd minute
   open Minute.xcodeproj
   ```
3. There is no manual dependency installation. Xcode resolves the one pinned Swift package, [FluidAudio](https://github.com/FluidInference/FluidAudio), automatically. It is used only for optional on-device speaker identification; see the dependency rule below before proposing another package.

The project uses Xcode's synchronized folder groups: files added under `Minute/`, `MinuteTests/`, `MinuteUITests/`, `MinuteWidgets/`, or `Shared/` are picked up automatically — no project-file surgery needed.

For physical-device builds, configure the app and the `MinuteWidgets` extension with the same paid Developer Team and shared App Group (`group.com.minuteapp.Minute`). The app target also needs access to the iCloud Documents container `iCloud.com.minuteapp.Minute`. If you do not control those identifiers, replace them with identifiers for your team or remove the related capabilities locally as described in the README.

> **Note:** opening the project may dirty `project.pbxproj` and the scheme — Xcode inserts your personal signing team (needed for device builds) and version stamps. That's expected; keep those changes local and don't include them in commits.

## Simulator caveats (read this before filing a "transcription is broken" issue)

| Capability | Simulator | Physical iPhone |
|---|---|---|
| Recording & playback | ✅ works (uses the Mac's microphone) | ✅ |
| Live transcription | ❌ `SpeechTranscriber` is unavailable on simulators by design | ✅ (first use downloads the model) |
| AI summaries | ✅ **if** the host Mac has Apple Intelligence enabled | ✅ on Apple Intelligence–capable iPhones |

The app is expected to degrade gracefully in every unsupported case — recording must always still work.

## Running tests

The examples below use an iPhone 17 Pro simulator. Substitute any installed iPhone listed by `xcrun simctl list devices available` if that device is not present on your machine.

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

- Unit tests use **Swift Testing** (`@Test` / `#expect`); UI tests use XCUITest.
- `SummarizationIntegrationTests` runs against the **real on-device model** and skips itself where the model is unavailable. Keep its assertions structural (non-flaky) — model output wording is nondeterministic.
- New logic needs tests. Pure logic (parsers, chunkers, exporters) belongs in `Support/` or `Services/` where it's testable without UI.

To match CI more closely, build first, run unit and UI tests separately, and skip the live Apple Intelligence integration suite on a model-less CI simulator:

```bash
xcodebuild build -project Minute.xcodeproj -scheme Minute \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

xcodebuild test -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MinuteTests \
  -skip-testing:MinuteTests/SummarizationIntegrationTests \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:MinuteUITests CODE_SIGNING_ALLOWED=NO
```

CI discovers an available iPhone simulator dynamically rather than depending on that example device name.

Run the same strict style gate as CI when SwiftLint is installed:

```bash
swiftlint --strict --reporter github-actions-logging
```

GitHub Actions also scan the full history for secrets and require a Conventional Commits-style PR title.

## The hard rules (privacy invariants)

Every PR must keep these true. They are the product:

1. **No meeting content on the wire except user-chosen copies.** No cloud transcription, cloud LLMs, telemetry, crash reporters, analytics SDKs, or remote content. The existing network paths are narrowly scoped: iOS may fetch Apple's on-device model assets; FluidAudio downloads its speaker model from Hugging Face when speaker identification is first used; and the two off-by-default iCloud options copy data only to the user's own account. None sends meeting content to the developer or a model provider. Any new network behavior needs prior discussion, a privacy review, and matching updates to public disclosures.
2. **No new data at rest without a delete path.** Anything written to disk must be removed by `MeetingStore.delete` (or the orphan sweep). Deleting a meeting must remove every app-owned byte of it. While iCloud Drive mirroring is enabled, the next sync removes Minute's notes, audio, and marker files for a deleted meeting; folders containing user-added files are preserved, and copies left after the user turns the toggle off are theirs to manage in Files.
3. **AI output stays grounded.** Summarization instructions must forbid invented decisions, owners, deadlines, names, or facts; missing owner/deadline is the literal `"Not specified"`. Don't weaken the instructions or the normalization in `SummarizationService`.
4. **Recording never depends on optional capabilities.** Transcription and summarization are best-effort extras; audio capture must start fast and survive their absence or failure.
5. **No new third-party dependencies** without prior discussion in an issue. FluidAudio is the current audited exception for optional offline speaker identification. Auditability, privacy-manifest coverage, licensing, model-host behavior, binary size, and removal strategy are part of any dependency review.

## Style

- Swift API Design Guidelines; SwiftUI + `@Observable`; small files (roughly ≤400 lines) organized by feature.
- Views stay thin — side effects live in `Services/` / `Recording/`.
- No silently swallowed errors: handle, surface to the user when actionable, or log via `os.Logger`.
- PR titles follow [Conventional Commits](https://www.conventionalcommits.org) because the squash-merge title becomes the commit subject on `main`: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.

## Pull requests

1. Branch from `main`, keep PRs focused on one change.
2. Use a Conventional Commits-style PR title; CI enforces it.
3. Make sure the relevant build, tests, and strict SwiftLint check pass locally (commands above).
4. Fill in the PR template — especially **how you tested** and the **privacy checklist**.
5. If you changed recording, transcription, speaker identification, or summarization behavior, note what you verified on a physical device vs. the simulator.

## Good first contributions

- Items on the [README roadmap](README.md#roadmap--known-limitations) — the structured action-item editor and focused UI-test additions are well-scoped starters
- Localization groundwork (String Catalogs are already enabled)
- Accessibility polish beyond the current VoiceOver labels
- More unit coverage for `SummarizationService` normalization edge cases

## Reporting bugs & security issues

- Bugs and feature requests: open a [GitHub issue](https://github.com/feihou/minute/issues) using the templates.
- Anything privacy- or security-sensitive (e.g. data left behind after deletion): please use GitHub's **private vulnerability reporting** on this repository ("Security" tab → "Report a vulnerability") instead of a public issue. If that option isn't visible, contact the maintainer directly via [@feihou](https://github.com/feihou).

## Code of conduct

Be excellent to each other — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

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
3. There are **no dependencies** to install — no SPM packages, no CocoaPods. Keep it that way unless a dependency is truly unavoidable (see rules below).

The project uses Xcode's synchronized folder groups: any file you add under `Minute/`, `MinuteTests/`, or `MinuteUITests/` is picked up automatically — no project-file surgery needed.

> **Note:** opening the project may dirty `project.pbxproj` and the scheme — Xcode inserts your personal signing team (needed for device builds) and version stamps. That's expected; keep those changes local and don't include them in commits.

## Simulator caveats (read this before filing a "transcription is broken" issue)

| Capability | Simulator | Physical iPhone |
|---|---|---|
| Recording & playback | ✅ works (uses the Mac's microphone) | ✅ |
| Live transcription | ❌ `SpeechTranscriber` is unavailable on simulators by design | ✅ (first use downloads the model) |
| AI summaries | ✅ **if** the host Mac has Apple Intelligence enabled | ✅ on Apple Intelligence–capable iPhones |

The app is expected to degrade gracefully in every unsupported case — recording must always still work.

## Running tests

```bash
xcodebuild -project Minute.xcodeproj -scheme Minute \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

- Unit tests use **Swift Testing** (`@Test` / `#expect`); UI tests use XCUITest.
- `SummarizationIntegrationTests` runs against the **real on-device model** and skips itself where the model is unavailable. Keep its assertions structural (non-flaky) — model output wording is nondeterministic.
- New logic needs tests. Pure logic (parsers, chunkers, exporters) belongs in `Support/` or `Services/` where it's testable without UI.

## The hard rules (privacy invariants)

Every PR must keep these true. They are the product:

1. **No app-owned network calls, and no user data on the wire by default.** No cloud transcription, no cloud LLMs, no telemetry, no crash reporters, no analytics SDKs, no remote fonts. The only permitted network activity is system-mediated: iOS downloading Apple's on-device model assets (speech / Apple Intelligence), which never carries meeting content, and — each behind its own off-by-default toggle in Settings — iOS including meeting data in the device's iCloud/computer backup (iCloud Backup) or syncing the browsable per-meeting folder the app mirrors locally (iCloud Drive Folder). The app itself never opens a connection in any of these. If a feature needs a server, it doesn't belong in Minute.
2. **No new data at rest without a delete path.** Anything written to disk must be removed by `MeetingStore.delete` (or the orphan sweep). Deleting a meeting must leave zero bytes of it behind. The iCloud Drive mirror follows the same rule while its toggle is on — the next sync removes a deleted meeting's folder; copies left after the user turns the toggle off are theirs to manage in Files, like any Share export.
3. **AI output stays grounded.** Summarization instructions must forbid invented decisions, owners, deadlines, names, or facts; missing owner/deadline is the literal `"Not specified"`. Don't weaken the instructions or the normalization in `SummarizationService`.
4. **Recording never depends on optional capabilities.** Transcription and summarization are best-effort extras; audio capture must start fast and survive their absence or failure.
5. **No third-party dependencies** without prior discussion in an issue. The zero-dependency build is a feature (auditability).

## Style

- Swift API Design Guidelines; SwiftUI + `@Observable`; small files (roughly ≤400 lines) organized by feature.
- Views stay thin — side effects live in `Services/` / `Recording/`.
- No silently swallowed errors: handle, surface to the user when actionable, or log via `os.Logger`.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.

## Pull requests

1. Branch from `main`, keep PRs focused on one change.
2. Make sure the full test suite passes locally (command above).
3. Fill in the PR template — especially **how you tested** and the **privacy checklist**.
4. If you changed recording, transcription, or summarization behavior, note what you verified on a physical device vs. the simulator.

## Good first contributions

- Items on the [README roadmap](README.md#roadmap--known-limitations) — CI setup and the structured action-item editor are well-scoped starters
- Localization groundwork (String Catalogs are already enabled)
- Accessibility polish beyond the current VoiceOver labels
- More unit coverage for `SummarizationService` normalization edge cases

## Reporting bugs & security issues

- Bugs and feature requests: open a [GitHub issue](https://github.com/feihou/minute/issues) using the templates.
- Anything privacy- or security-sensitive (e.g. data left behind after deletion): please use GitHub's **private vulnerability reporting** on this repository ("Security" tab → "Report a vulnerability") instead of a public issue. If that option isn't visible, contact the maintainer directly via [@feihou](https://github.com/feihou).

## Code of conduct

Be excellent to each other — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## What

<!-- What does this PR change? -->

## Why

<!-- What problem does it solve? Link related issues: Fixes #... -->

## How was it tested?

- [ ] `xcodebuild … test` passes locally (unit + UI tests)
- [ ] `swiftlint --strict --reporter github-actions-logging` passes locally
- [ ] Verified on a physical iPhone (required for recording/transcription changes)
- [ ] Verified graceful behavior when transcription, the speaker model, or Apple Intelligence is unavailable

## Release hygiene

- [ ] PR title follows Conventional Commits (`feat:`, `fix:`, `docs:`, and so on)

## Privacy checklist

- [ ] No new network behavior, telemetry, or dependency introduced — or the rationale, data flow, and disclosure updates are explained above
- [ ] Any new data written to disk is removed by meeting deletion (or the orphan sweep)
- [ ] AI summarization stays grounded (no invented facts; `"Not specified"` fallback intact)

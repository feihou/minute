## What

<!-- What does this PR change? -->

## Why

<!-- What problem does it solve? Link related issues: Fixes #... -->

## How was it tested?

- [ ] `xcodebuild … test` passes locally (unit + UI tests)
- [ ] Verified on a physical iPhone (required for recording/transcription changes)
- [ ] Verified graceful behavior when transcription / Apple Intelligence is unavailable

## Privacy checklist

- [ ] No network calls, telemetry, or third-party SDKs introduced
- [ ] Any new data written to disk is removed by meeting deletion (or the orphan sweep)
- [ ] AI summarization stays grounded (no invented facts; `"Not specified"` fallback intact)

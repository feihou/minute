# PR #28 Review Fixes Design

## Goal

Repair the actionable correctness and privacy issues introduced by merged PR #28 without redesigning the iCloud Drive mirror or changing its opt-in semantics.

## Validated issues

1. Duplicate cleanup treats a same-named file as a healthy recording. If the kept folder contains a truncated file while a duplicate contains the last good copy, the duplicate is deleted.
2. The background mirror outlives its UIKit background assertion and is not cancelled when the app returns to the foreground.
3. Store fallback hides all backup controls even though the device-backup preference still governs old persistent data.
4. `NSUbiquitousContainers` names `iCloud.com.minuteapp.Minute`, while the entitlements derive a different identifier when `PRODUCT_BUNDLE_IDENTIFIER` is overridden.
5. README and Settings contain absolute “nothing leaves the phone” copy that conflicts with the two opt-in backup options.

## Approaches considered

### Recommended: focused safety fixes

Keep the current actor and mirror algorithm. Require a readable local source before deleting duplicate audio copies; introduce a small cancellable owner for lifecycle-triggered background work; keep the backup section visible in fallback; use the production iCloud container literal consistently; and narrow the privacy copy. This is the smallest reviewable change and preserves existing behavior outside the defects.

### Broader service rewrite

Split the 784-line mirror into naming, ownership, reconciliation, and lifecycle services. This could improve maintainability but would greatly expand the regression surface while repairing data-safety bugs, so it is rejected for this fix.

### Documentation-only mitigation

Document the duplicate, lifecycle, and signing limitations and rely on later syncs or manual cleanup. This is rejected because it leaves preventable loss of the last healthy mirrored recording and keeps privacy controls unreachable during fallback.

## Design

### Duplicate safety

Duplicate folders may be removed only when the kept folder has locally readable bytes matching the readable local recording. Exact streaming comparison catches same-size corruption and repairs it from the source before pruning another healthy copy. The expensive comparison runs only when duplicate cleanup is pending; ordinary syncs retain the size fast path for large immutable recordings. If the meeting has no recording, no recording proof is required. If the model names a recording but the local source cannot be read, all duplicate folders remain until a later sync can compare the kept copy with the source. An iCloud placeholder is not sufficient proof for destructive cleanup because its bytes cannot be verified locally.

### Lifecycle cancellation

`BackgroundMirrorTask` owns the Swift task, the UIKit background-task token, and a thread-safe cancellation flag. Its continuation predicate is composed with the existing task-cancellation and Settings-toggle checks. Returning to the foreground explicitly cancels the owner. UIKit expiration flips the same flag and ends the assertion, so the mirror stops at its next existing safety boundary and removes any partial copy.

### Fallback privacy controls

Only storage usage and destructive local deletion stay hidden when the persistent store falls back to memory. The backup section remains reachable: users can still exclude the old Application Support tree from device backups and can turn off a previously enabled iCloud Drive preference. An attempted iCloud Drive enable continues to fail safely through the existing ephemeral-store guard and reports the storage fallback as the blocker rather than incorrectly directing the user to iCloud settings.

### Container configuration and copy

Both iCloud entitlement arrays use the production literal `iCloud.com.minuteapp.Minute`, matching the `NSUbiquitousContainers` key. Non-owner device builds must remove or replace both the entitlements and matching container metadata. User-facing copy says processing is on-device and backups are optional, rather than claiming data can never leave the phone.

## Verification

- Add regression tests where the kept duplicate has a truncated recording, same-size corruption, or only an iCloud placeholder. The mirror must repair from a readable source or preserve another healthy duplicate until the kept copy can be verified locally.
- Add an async regression test proving explicit cancellation makes lifecycle work observe `shouldContinue == false`.
- Run the three PR-related unit suites, then all unit tests excluding the real-model integration suite.
- Build with an alternate bundle identifier and inspect the processed Info.plist plus simulated entitlements to confirm the container identifiers remain equal.
- Run the repository lint/static checks and inspect the final diff independently.

## Remaining manual check

A physical signed iPhone with an iCloud account is still required to exercise UIKit background expiration and the real ubiquity container end to end.

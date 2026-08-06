# Code and Documentation Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align every maintained public, contributor, privacy, App Store, and repository-workflow document with the behavior and configuration that ship in the current Minute codebase.

**Architecture:** Treat code, entitlements, package resolution, tests, and CI workflows as the source of truth. Update one documentation surface at a time, then run repository-wide contradiction, link, plist, build, lint, and test checks; preserve historical design/implementation plans as point-in-time records.

**Tech Stack:** Markdown, YAML, Swift/Xcode 26, SwiftLint, GitHub Actions

## Global Constraints

- Do not change application behavior as part of this documentation-alignment pass.
- Do not add or upgrade dependencies.
- Keep the privacy promise precise: meeting content is processed on device, optional user-controlled iCloud copies are off by default, and FluidAudio downloads speaker-identification models from Hugging Face without uploading meeting content.
- Distinguish verified repository behavior from App Store/legal guidance that still requires release-owner confirmation.
- Keep historical files under `docs/superpowers/specs/` and earlier `docs/superpowers/plans/` unchanged.

---

### Task 1: Public product and architecture documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: shipped features and constraints from `Minute/`, `MinuteWidgets/`, `Shared/`, the Xcode project, and CI workflows.
- Produces: the canonical public feature, privacy, requirement, setup, architecture, and roadmap description used by contributors and release copy.

- [x] **Step 1: Correct dependency and network claims**

Replace zero-dependency/no-app-network wording with the pinned FluidAudio dependency and its optional one-time Hugging Face model download, while preserving the no-meeting-content-upload guarantee.

- [x] **Step 2: Add missing shipped features**

Document speaker identification and renaming, Live Activity, audio import, search, summary templates/languages/context, auto-summarize, and re-transcription without overstating device/language availability.

- [x] **Step 3: Refresh architecture and roadmap**

Add the current job, import, backup, diarization, widget, and Live Activity services; remove completed diarization and CI roadmap items; describe summary generation as manual or optional post-save automation.

- [x] **Step 4: Check public claims against code**

Run: `rg -n "No third-party|no third-party|one network operation|Speaker awareness|CI \(GitHub" README.md`

Expected: no stale claim matches.

### Task 2: Contributor and repository workflow documentation

**Files:**
- Modify: `CONTRIBUTING.md`
- Modify: `.github/PULL_REQUEST_TEMPLATE.md`
- Modify: `.github/ISSUE_TEMPLATE/feature_request.md`
- Modify: `.github/dependabot.yml`

**Interfaces:**
- Consumes: `Package.resolved`, synchronized Xcode groups, entitlements, `.swiftlint.yml`, and `.github/workflows/`.
- Produces: setup, dependency, privacy-review, CI, PR-title, lint, and contribution guidance consistent with enforced automation.

- [x] **Step 1: Correct setup and dependency guidance**

Explain that Xcode resolves the pinned FluidAudio Swift package automatically; include `MinuteWidgets/` and `Shared/` synchronized groups and the App Group plus iCloud signing requirements.

- [x] **Step 2: Document local and CI verification**

Add the generic simulator build, unit/UI test split, integration-test exception, strict SwiftLint command, secret scan, and Conventional Commit PR-title gate.

- [x] **Step 3: Update repository templates and comments**

Make the feature-request privacy prompt local-first rather than absolutely network-free, require an accurate PR privacy/dependency disclosure, and correct Dependabot's stale zero-package comment.

- [x] **Step 4: Check contributor claims**

Run: `rg -n "no SPM|No third-party dependencies|No app-owned network|CI setup|app itself has no package" CONTRIBUTING.md .github`

Expected: no stale claim matches.

### Task 3: Privacy and retention documentation

**Files:**
- Modify: `docs/privacy-policy.md`

**Interfaces:**
- Consumes: storage, backup, widget snapshot, model-download, deletion, and settings behavior from `MeetingStore`, `ICloudDriveBackup`, `DiarizationService`, `AppSettings`, and privacy manifests.
- Produces: the public privacy policy and the retention/deletion description used by App Store review.

- [x] **Step 1: Clarify model downloads and local processing**

Describe the Apple system speech-asset download separately from the FluidAudio/Hugging Face speaker-model download and state what request metadata can leave the device.

- [x] **Step 2: Correct backup and deletion scope**

Explain that deleting a meeting removes app-owned mirror artifacts on the next enabled sync, preserves user-added files/folders, and that Delete All Meetings does not erase app preferences or summary context.

- [x] **Step 3: Disclose the summary-context backup limitation**

Until code storage is changed, avoid promising that UserDefaults-backed summary context can never participate in the user's standard device backup.

- [x] **Step 4: Validate policy structure and links**

Check every local link target and every privacy claim against the cited implementation files.

### Task 4: App Store release documentation

**Files:**
- Modify: `docs/app-store/metadata.md`
- Modify: `docs/app-store/4-privacy.png`

**Interfaces:**
- Consumes: the aligned README/privacy policy, current UI behavior, Info.plist, entitlements, package lock, and current official Apple guidance.
- Produces: release-owner-ready product copy, privacy questionnaire rationale, review notes, and clearly marked confirmation items.

- [x] **Step 1: Re-ground provenance in this checkout**

Remove absolute paths to obsolete worktrees and list stable repository-relative source files plus the verification date.

- [x] **Step 2: Tighten product and review copy**

Make transcription availability conditional on device language/model readiness, make speaker perspectives conditional on speaker labels, and match the current network/backup/deletion behavior.

- [x] **Step 3: Separate verified facts from release decisions**

Mark pricing, rating outcome, support URL acceptance, export classification, and App Privacy answers as release-owner confirmations where repository inspection alone cannot prove them.

- [x] **Step 4: Recalculate metadata limits**

Verify app name, subtitle, promotional text, description, and keyword character counts after edits.

- [x] **Step 5: Refresh the privacy screenshot**

Replace the broad “No server” marketing line with copy that accurately distinguishes on-device meeting processing from model downloads and optional iCloud backup, then inspect the rendered image.

### Task 5: Integrated verification and review

**Files:**
- Verify: all changed files
- Verify: all tracked Markdown links and referenced images
- Verify: `Minute/Info.plist`, entitlements, and privacy manifests

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: an evidence-backed final diff with remaining code risks clearly separated from documentation changes.

- [x] **Step 1: Scan for contradictions and workspace-specific paths**

Run repository-wide searches for stale zero-dependency, single-network-operation, pending-CI/diarization, and obsolete absolute-worktree wording.

- [x] **Step 2: Validate structured files and links**

Run `plutil -lint` on plist/entitlement/privacy files and a local Markdown-link/image-target check.

- [x] **Step 3: Run project verification**

Run the generic simulator build, unit tests with the integration-test exception, UI tests, and strict SwiftLint when installed.

- [x] **Step 4: Review the final diff**

Confirm only intended documentation and repository-copy files changed, every public claim has a code/config source, and code-review findings are reported without claiming they were fixed.

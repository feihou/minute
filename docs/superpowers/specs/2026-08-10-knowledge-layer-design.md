# Minute Knowledge Layer ("Brain") — Design Spec

**Date:** 2026-08-10
**Status:** Approved design, pending implementation plan
**Phase:** Second-brain evolution, phase 1 (knowledge base) + milestone 2 (chat)

## Context and goal

Minute today is a meeting-notes app: record → transcribe → summarize, all on-device.
This spec turns it into a second brain: a persistent, reviewable knowledge base that
Minute builds about the user over time — their people, projects, topics, and self —
from everything they capture, with export to an Obsidian-compatible markdown vault
and (milestone 2) a chat surface grounded in that knowledge.

Product decisions made during brainstorming (2026-08-10):

1. **Core magic:** "It knows me over time" — a persistent knowledge base, not chat-first,
   not resurfacing-first, not export-first.
2. **Visibility:** Visible and reviewable — browsable entity pages, correction affordances.
   (Trust model refined below: editor, not gatekeeper.)
3. **Sequencing:** Knowledge layer first, built on the existing meeting corpus.
   Capture-anything (quick voice notes) comes after this phase.
4. **Chat:** Same phase, second milestone, after the KB ships.

Strategic grounding: the Aug 2026 competitive research (see the SecondBrain vault note
"Minute — From Meeting Notes to Second Brain") found nobody credibly occupies
"on-device capture + on-device organization" on iPhone. The cross-note memory graph is
the defensible layer Apple's built-ins do not touch.

This design was adversarially reviewed by a three-lens critique panel
(on-device-AI feasibility, second-brain UX/trust, knowledge-system data modeling);
all blocker and important findings are folded in below.

## 1. Data model

Two new SwiftData `@Model` classes in the existing store, alongside `Meeting`.
They are real models with a declared relationship — **not** the codable-array-blob
pattern `Meeting` uses for segments/summary — because facts must be individually
queryable and searchable.

```swift
@Model final class KnowledgeEntity {
    var id: UUID
    var name: String
    var kind: EntityKind          // .person, .project, .topic, .me (singleton)
    var aliases: [String]         // grows via review-card reassignment and merges
    var synthesis: String?        // FM-generated 2–3 sentence narrative, regenerated
                                  // when facts change
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \KnowledgeFact.entity)
    var facts: [KnowledgeFact]
    var redirectTo: UUID?         // set when this entity was merged away; see §5
}

@Model final class KnowledgeFact {
    var id: UUID
    var text: String              // user-editable display text
    var originalText: String      // verbatim extractor output; NEVER mutated by edits;
                                  // ALL dedup (incl. tombstone matching) runs on this
    var status: FactStatus        // .autoCaptured, .suggested, .approved, .rejected,
                                  // .superseded
    var sourceMeetingID: UUID     // plain UUID, no Meeting relationship; UI tolerates
                                  // deleted meetings
    var sourceQuote: String?      // only set if validated by fuzzy substring match
                                  // against the transcript; nil otherwise
    var capturedAt: Date          // meeting date — facts are timestamped observations
    var reviewedAt: Date?
    var supersededByID: UUID?
    var fingerprint: String?      // salted hash of (originalText, entity ID); set on
                                  // rejection, when text/originalText/sourceQuote are
                                  // cleared — the only thing a tombstone retains
    var entity: KnowledgeEntity
}
```

`Meeting` gains one field: `knowledgeExtractedAt: Date?` — the backfill cursor
stamp (§5).

Rules:

- Facts are **timestamped observations, not eternal truths**. Supersession (§4) is how
  truth changes; history is preserved, not deleted.
- To-many relationship order is undefined in SwiftData — every consumer sorts facts by
  `capturedAt` explicitly.
- **Rejection genuinely forgets** (privacy): rejecting a fact clears `text`,
  `originalText`, and `sourceQuote` and sets `fingerprint`; dedup matches candidates by
  hashing them the same way. Tombstones are fingerprints, never sentences.
- Every `ModelContainer` creation site (app startup, preview container, tests) must be
  updated in the same commit that introduces the models. A migration test opens a copy
  of a current-schema on-disk store with the new schema — a KB schema bug must never
  trip the existing ephemeral-storage fallback and take meetings down with it.
- KB data inherits the existing iCloud-backup-exclusion policy automatically (same
  Application Support tree).

## 2. Extraction pipeline

A new job in `MeetingJobs`, running after summarization succeeds.

- **Chunking:** extraction reuses the same chunk-size + context-overflow-halving
  machinery as `SummarizationService` (the 4,096-token FM window is hard; hour-long
  meetings do not fit otherwise). Candidates from all chunks merge mechanically in code —
  no second model pass.
- **Output:** FoundationModels guided generation, `@Generable` candidate:
  `{entityName, entityKind, fact, supportingQuote}`. Guides instruct: only
  explicitly-stated durable facts (roles, projects, decisions, preferences,
  relationships, commitments), not meeting minutiae.
- **Quote validation:** `supportingQuote` is checked by fuzzy substring search against
  the transcript; no match → stored as nil. No UI ever presents an unvalidated quote
  as evidence.
- **Entity resolution happens in code, not in the prompt.** The prompt receives only a
  prefiltered hint list — entities whose names/aliases lexically appear in this
  meeting's transcript or speaker names, hard-capped (~20). Emitted `entityName` is
  normalized (casefold, strip diacritics, token-sort) and matched against ALL existing
  names + aliases. High token overlap without exact match → entity is created but a
  "possible duplicate of X?" review card is enqueued; never a silent fork. The user's
  own name / self-speaker label hard-maps to the Me singleton in resolution code.
- **Idempotent re-runs** (retry-next-launch, re-transcribe/re-summarize flows,
  backfill re-runs): re-extraction of a meeting replaces that meeting's still-`suggested`
  facts wholesale. Dedup keys on `(entity, sourceMeetingID)` with low-threshold text
  similarity within that scope (same-meeting near-dupes are re-extraction paraphrases);
  cross-meeting near-dupes are never auto-dropped — they surface as "possible duplicate"
  cards (negation flips like "Bob joined"/"Bob left" must not silently merge). All
  matching runs against `originalText`, so user edits can't break dedup.
- **Guardrail refusals** are expected, visible outcomes ("2 meetings skipped"), handled
  with the same survive-refusal patterns as the notes pipeline, using the same
  permissive-transformations session configuration.
- **Engine scope:** FoundationModels-only in v1 (requires Apple Intelligence,
  A17 Pro+). Devices without it see the Brain tab in a "requires Apple Intelligence"
  state. MLX-based extraction is future work.
- User deletion of an approved fact converts it to a rejected tombstone (fingerprint),
  never a hard delete — otherwise the next backfill resurrects it.

## 3. Trust model — editor, not gatekeeper

Approval-gating every fact collapses into approve-all theater at real volume
(20–30 decisions/day); the gate is reserved for what deserves it.

- **High-confidence facts** (validated quote + exact entity match + no contradiction
  with an approved fact) flow **directly onto entity pages** as `.autoCaptured`, with:
  a visible "auto-captured" treatment, one-tap remove, and a "Recently learned" undo
  stream on the Brain tab. Trust comes from provenance + cheap reversibility.
- **The review queue gates exactly three classes:**
  1. facts about the Me entity,
  2. facts contradicting an approved fact — the card shows both; one tap "replaces
     this" marks the old fact `.superseded` on approval (§4),
  3. facts on a newly-created entity.
  This yields ~3–5 decisions/day.
- **Review cards fix entity errors fast** (the dominant v1 error class is
  right-fact-wrong-entity): the card's entity name is tappable → fuzzy-matched picker
  ("Sara → did you mean Sarah Chen?") reassigns the fact and records an alias in one
  gesture. Name near-duplicate checks run at suggestion-creation time and surface as a
  merge question at the top of a review session.
- **Contradiction detection v1 is deterministic, no model call:** a candidate fact on
  an entity with an approved, non-superseded fact whose token overlap is significant but
  below the near-duplicate threshold is treated as a potential update and routed to
  review (class 2). Misses are acceptable — they surface later as stale facts the user
  edits; false positives cost one review card.
- **Two rejection verbs:** "Not true" (feeds the dedup tombstone) vs "Don't track
  this" (removes without blocking future correct re-extraction).
- **Auto-archive:** suggestions unreviewed after 14 days archive silently — no guilt
  inbox, no growing badge.
- A "Review everything" setting (default off) restores full gating for users who want it.

## 4. Supersession lifecycle

- `KnowledgeFact.supersededByID` links an outdated fact to its replacement;
  status `.superseded`.
- Cheapest correct wiring: supersession is decided at review time by the human who is
  already looking at both facts (§3, class 2).
- Retrieval (`retrieve` tool, entity-page search) excludes superseded facts by default
  and sorts by `capturedAt`; chat instructions say "prefer the most recent fact and
  state its date".
- Export renders superseded facts under a "History" subsection, not interleaved as
  current truth.

## 5. Backfill and cold start

- **Foreground-only, newest-first, resumable cursor**: each meeting is stamped
  (`knowledgeExtractedAt`) after processing; the job runs serially only while the scene
  is active and `ProcessInfo.thermalState <= .fair`; `.rateLimited` and backgrounding
  are pause-and-resume, not failure. One save per meeting through a background
  ModelContext/ModelActor; only persistent IDs cross to the main actor.
- **No gated review wall.** The Brain tab fills in live with a progress row ("your
  Brain fills in as you use Minute"). Newest-first means it is useful within the first
  minute.
- **Onboarding is one bounded pass (~10 taps):** open with the Me page reveal —
  "here's what Minute picked up about you" — then confirm/merge the top ~5 people and
  projects (an entity-resolution pass; one merge decision retires dozens of downstream
  fact errors). Everything else stays browsable as draft and is confirmed lazily
  (approve-while-reading affordance on entity pages, per-meeting confirmation for new
  meetings).

## 6. Brain tab and entity pages

- New top-level tab. Sections: **Me, People, Projects, Topics**, plus the "Recently
  learned" stream and the backfill progress row.
- Entity page: **synthesis paragraph on top** (the system saying something *about* the
  entity), dated facts with source-meeting chips underneath (deep links via existing
  `MeetingDeepLinkState`; chips tolerate deleted meetings). Facts are the receipts under
  the narrative, not the content.
- **Merge is an atomic operation:** reparent ALL facts (approved, suggested,
  tombstones) to the winner; union aliases and add the loser's name as an alias (so
  future extraction resolves to the winner — merge cannot be undone by the pipeline);
  run an intra-entity dedup pass pushing collisions to the review queue; keep the loser
  as a redirect record (`redirectTo`) so source chips, deep links, and future unmerge
  survive. Unit-tested as merge-then-re-extract.
- **"Forget this person/project"** is first-class on every entity page: purges entity,
  facts, and tombstones completely. Deletion depth is a trust feature.
- **Pre-meeting brief — the delivery route:** on the meeting screen, when participants
  match known entities, show "What you know": last 3 facts + open commitments per
  matched entity. This makes the brain show up in the surface the user already visits
  daily, delivering "it knows me" in week one, before chat exists.
- Search-across-facts is deferred to v1.1 (corpus is small; browse + brief cover it).
- A persistent "On-device only — never leaves your iPhone" line on the Brain tab.

## 7. Export

"Export Brain" in the existing `NotesExporter` surface:

- Writes a **fresh timestamped snapshot folder** (never in-place updates — deletion-by-
  omission cannot strand stale files in a synced vault).
- One markdown file per entity: YAML frontmatter with `aliases:` (including
  merged-away names, so Obsidian resolves old links), synthesis, facts as dated
  bullets, superseded facts under "History".
- **Filenames are sanitized and collision-disambiguated** once, deterministically:
  strip path-illegal characters, then disambiguate clashes (including case-folded
  clashes on APFS) with kind or short id — e.g. `Atlas (Project).md`. Every
  `[[wiki-link]]` is generated from the final sanitized filename, never the raw name.
- Per-meeting notes export alongside so fact wiki-links resolve; the folder opens
  directly as an Obsidian vault.
- **People pages are excluded from export by default** (explicit opt-in toggle), since
  export is the main vector for a private dossier becoming a shared artifact. The
  export confirmation states exactly which entities/files will be written.
- Golden-file tests: a name containing "/", a case-collision pair, a person/project
  name clash.

## 8. Chat — "Ask your brain" (milestone 2)

- **One FM session per question.** The 4k window cannot hold multi-turn tool traffic;
  continuity comes from a rolling 1–2 sentence conversation summary re-seeded into each
  fresh session, not replayed turns. Chat history is ephemeral in v1.
- **A single `retrieve(query)` tool** (not three overlapping tools — the ~3B model
  chooses poorly among them), returning a hard-capped payload: top ~5 facts, truncated,
  short IDs, superseded excluded, recency-sorted. Backed by lexical search over facts +
  entity names/aliases + meeting titles; no vector index in v1 (corpus is hundreds of
  short facts).
- **Citations cannot be hallucinated:** the tool implementation logs exactly which
  fact/meeting IDs it served during the session; citation chips are built app-side from
  that log. The model's prose never carries IDs.
- On context overflow, retry once as a one-shot prompt with the retrieved facts inlined.

## 9. Error handling

- Extraction failures are non-fatal: skip, log, retry next launch (existing
  `MeetingJobs` retry pattern).
- Guardrail refusal skips the meeting visibly without blocking the queue.
- KB shares the store's existing ephemeral in-memory fallback; the migration test (§1)
  protects meetings from KB schema bugs.
- Backfill obeys thermal/foreground constraints (§5); a stuck cursor self-heals by
  re-checking stamps.

## 10. Testing

- **Unit:** resolution normalization (case/diacritics/token-sort), dedup + idempotent
  re-extraction, tombstone fingerprint matching after user edits, merge-then-re-extract,
  supersession transitions, export filename sanitization golden files.
- **Integration:** extraction job over seeded transcripts (the simulator lacks
  SpeechTranscriber but has FoundationModels); backfill cursor resume after simulated
  interruption; migration test from current-schema store copy.
- **UI:** review-card flows (approve / replace / reassign-entity / both reject verbs),
  merge picker, Me-page onboarding pass.
- `DemoSeed` extended with a populated Brain for App Store screenshots.

## 11. Build order

1. **Models + extraction + backfill** — schema, extraction job, resolution, dedup,
   cursor. (Testable headless before any UI.)
2. **Brain tab + review + pre-meeting brief** — entity pages, synthesis, review cards,
   onboarding pass, "Recently learned", forget/merge.
3. **Export** — snapshot vault writer on `NotesExporter`.
4. **Chat** — retrieve tool, session-per-question, app-side citations.

## Out of scope (this phase)

- Capture-anything entry points (lock screen / Action button / Watch / thought mode) —
  next phase, per sequencing decision.
- MLX-based extraction for pre-A17 devices.
- Vector embeddings / semantic retrieval (lexical is sufficient at this corpus size).
- Proactive digests and cross-note "related links" resurfacing beyond the pre-meeting
  brief.
- Importing Apple call recordings / Voice Memos.

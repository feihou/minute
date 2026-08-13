#if DEBUG
import Foundation
import SwiftData

/// Replaces the library with realistic demo meetings when the app is launched
/// with `-SeedDemoData` — used to stage App Store screenshots. Debug-only and
/// launch-argument-gated: it can never run in a shipping build.
@MainActor
enum DemoSeed {
    /// Fixed id for the richest demo meeting so screenshot automation can
    /// open it deterministically (see MeetingListView's -DemoOpenMeeting).
    static let heroMeetingID = UUID(uuidString: "0A0A0A0A-0A0A-40A0-80A0-0A0A0A0A0A0A")!

    static func seedIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-SeedDemoData") else { return }
        let context = container.mainContext
        if let existing = try? context.fetch(FetchDescriptor<Meeting>()) {
            for meeting in existing { context.delete(meeting) }
        }
        if let existingEntities = try? context.fetch(FetchDescriptor<KnowledgeEntity>()) {
            for entity in existingEntities { context.delete(entity) }
        }
        let meetings = demoMeetings()
        for meeting in meetings { context.insert(meeting) }
        seedKnowledge(context: context, meetings: meetings)
        try? context.save()
    }

    /// Populates the Brain with pre-synthesized entities and facts so
    /// screenshots never trigger a real FM extraction or synthesis pass.
    ///
    /// Note: local helpers below are named `makeFact`/`makeEntity` (not
    /// `fact`/`entity`) — the make- prefix keeps these local helpers visually
    /// distinct from the model types and parameter labels they build.
    private static func seedKnowledge(context: ModelContext, meetings: [Meeting]) {
        let now = Date.now
        let hero = heroMeetingID
        let designSyncID = meetings.first { $0.title.hasPrefix("Design Sync") }?.id ?? hero
        let customerCallID = meetings.first { $0.title.hasPrefix("Customer Call") }?.id ?? hero

        func makeFact(
            _ text: String, _ status: FactStatus, _ meetingID: UUID, daysAgo: Double,
            quote: String? = nil, entity: KnowledgeEntity
        ) {
            context.insert(KnowledgeFact(
                text: text, originalText: text, status: status, sourceMeetingID: meetingID,
                sourceQuote: quote, capturedAt: now.addingTimeInterval(-daysAgo * 86_400), entity: entity,
                createdAt: now.addingTimeInterval(-daysAgo * 86_400 + 3_600)
            ))
        }
        func makeEntity(_ name: String, _ kind: EntityKind, aliases: [String] = [], synthesis: String) -> KnowledgeEntity {
            let entity = KnowledgeEntity(name: name, kind: kind, aliases: aliases, synthesis: synthesis)
            context.insert(entity)
            return entity
        }

        let me = makeEntity("Sam", .me, synthesis: "You run the weekly product sync and own the Q3 scope. You committed SSO for Q3 and moved the analytics dashboard to Q4.")
        makeFact("Committed SSO for Q3, moving the analytics dashboard to Q4", .approved, hero, daysAgo: 0.1, entity: me)
        makeFact("Owns the decision on Japan-launch localization timing", .suggested, hero, daysAgo: 0.1, entity: me)

        let priya = makeEntity("Priya", .person, synthesis: "Your product lead for onboarding. She shipped the redesigned flow with 2.4 and is taking the lead on the Japan launch checklist.")
        makeFact("Leads the onboarding redesign; completion up 18% in beta", .autoCaptured, hero, daysAgo: 0.1,
                 quote: "The new onboarding flow is testing really well", entity: priya)
        makeFact("Taking the lead on the Japan launch checklist", .approved, designSyncID, daysAgo: 1.3, entity: priya)

        let diego = makeEntity("Diego", .person, synthesis: "Your engineer on offline mode. He scoped sync at two weeks and lands the storage layer first to de-risk the freeze.")
        makeFact("Scoped offline sync at ~2 weeks with last-write-wins for v1", .autoCaptured, hero, daysAgo: 0.1, entity: diego)
        makeFact("Landing the offline storage layer for review by Friday", .autoCaptured, hero, daysAgo: 0.1, entity: diego)

        let mei = makeEntity("Mei", .person, synthesis: "Your enterprise lead. She's unblocking three waiting accounts with SSO and owns the Northwind relationship.")
        makeFact("Three enterprise accounts are waiting on SSO", .autoCaptured, hero, daysAgo: 0.1, entity: mei)
        makeFact("Owns the Northwind Logistics relationship", .autoCaptured, customerCallID, daysAgo: 3.2, entity: mei)

        let sso = makeEntity("SSO", .project, synthesis: "Committed for Q3 in place of the analytics dashboard. It's the hard procurement requirement for Northwind and two other accounts.")
        makeFact("Committed for Q3; analytics dashboard moved to Q4 to make room", .approved, hero, daysAgo: 0.1, entity: sso)
        makeFact("Hard procurement requirement for Northwind", .autoCaptured, customerCallID, daysAgo: 3.2, entity: sso)

        let onboarding = makeEntity("Onboarding Redesign", .project, synthesis: "Shipping with release 2.4, old flow behind a flag for one release. Beta completion is up 18% and permission-step drop-off is gone.")
        makeFact("Ships with 2.4; old flow stays behind a flag for one release", .approved, hero, daysAgo: 0.1, entity: onboarding)
        makeFact("Permission-screen copy rewritten in plain language", .autoCaptured, designSyncID, daysAgo: 1.2, entity: onboarding)

        let japan = makeEntity("Japan Launch", .topic, synthesis: "Localization timing is the open question — English-first or localized onboarding. Priya owns the checklist.")
        makeFact("Open question: localize onboarding or ship English-first", .suggested, hero, daysAgo: 0.1, entity: japan)

        // Pre-filled narratives must read as fresh, or the entity page fires
        // a real FM synthesis during screenshots. Synthesis speaks settled
        // facts only, so the seed mirrors that: draft-only entities carry no
        // narrative, exactly as production would render them.
        for entity in [me, priya, diego, mei, sso, onboarding, japan] {
            entity.synthesizedFactCount = entity.settledFacts.count
            if entity.settledFacts.isEmpty {
                entity.synthesis = nil
            }
        }
    }

    private static func demoMeetings() -> [Meeting] {
        let now = Date.now
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour

        let roadmap = Meeting(
            id: heroMeetingID,
            title: "Q3 Product Roadmap Review",
            createdAt: now - 2 * hour,
            duration: 42 * 60 + 17,
            segments: [
                TranscriptSegment(
                    text: "Alright, everyone's here — let's walk the Q3 board. Priya, do you want to start with onboarding?",
                    start: 4, end: 11, speaker: 0
                ),
                TranscriptSegment(
                    text: "Sure. The new onboarding flow is testing really well. Completion is up eighteen percent "
                        + "in the beta cohort, and drop-off at the permissions step is basically gone.",
                    start: 12, end: 26, speaker: 1
                ),
                TranscriptSegment(
                    text: "That matches what we see in support — almost no confusion emails since the redesign.",
                    start: 27, end: 34, speaker: 2
                ),
                TranscriptSegment(
                    text: "Nice. My proposal is we ship it with 2.4 and keep the old flow behind a flag for one release.",
                    start: 35, end: 44, speaker: 1
                ),
                TranscriptSegment(
                    text: "Agreed. Next: offline mode. Diego, where did the spike land?",
                    start: 45, end: 51, speaker: 0
                ),
                TranscriptSegment(
                    text: "The sync engine can queue writes locally with about two weeks of work. Conflict "
                        + "resolution is the hard part — I'd keep last-write-wins for v1 and revisit merging later.",
                    start: 52, end: 68, speaker: 3
                ),
                TranscriptSegment(
                    text: "Two weeks puts us right at the feature freeze. Can we de-risk by landing the storage layer first?",
                    start: 69, end: 78, speaker: 0
                ),
                TranscriptSegment(
                    text: "Yes — storage layer is separable. I can have it reviewed by Friday.",
                    start: 79, end: 85, speaker: 3
                ),
                TranscriptSegment(
                    text: "On pricing: enterprise keeps asking for SSO. If we want it in Q3 we need a decision today.",
                    start: 86, end: 96, speaker: 2
                ),
                TranscriptSegment(
                    text: "Let's commit to SSO for Q3 and move the analytics dashboard to Q4. It's the only trade that fits.",
                    start: 97, end: 107, speaker: 0
                ),
                TranscriptSegment(
                    text: "Works for me. I'll update the enterprise deck and let the three waiting accounts know this week.",
                    start: 108, end: 116, speaker: 2
                ),
                TranscriptSegment(
                    text: "One open thing: do we localize onboarding for the Japan launch, or ship English first?",
                    start: 117, end: 125, speaker: 1
                ),
                TranscriptSegment(
                    text: "Let's take that offline with the localization vendor — I don't want to guess at the timeline.",
                    start: 126, end: 134, speaker: 0
                ),
            ],
            summary: MeetingSummary(
                overview: "The team locked the Q3 scope: the redesigned onboarding ships with 2.4, "
                    + "offline mode lands in two phases starting with the storage layer, and SSO "
                    + "replaces the analytics dashboard in the Q3 commitment.",
                keyPoints: [
                    "New onboarding lifted completion 18% in the beta cohort",
                    "Offline sync needs ~2 weeks; conflict resolution stays last-write-wins for v1",
                    "Enterprise accounts are blocked on SSO; three deals waiting",
                    "Analytics dashboard moves to Q4 to make room for SSO",
                ],
                decisions: [
                    "Ship the new onboarding flow with release 2.4, old flow behind a flag for one release",
                    "Commit SSO for Q3; move the analytics dashboard to Q4",
                ],
                actionItems: [
                    ActionItem(task: "Land the offline storage layer for review", owner: "Diego", deadline: "Friday"),
                    ActionItem(
                        task: "Update the enterprise deck and notify waiting accounts about SSO",
                        owner: "Mei", deadline: "This week"
                    ),
                    ActionItem(
                        task: "Get a localization timeline from the vendor for the Japan launch",
                        owner: "Sam", deadline: ActionItem.notSpecified
                    ),
                ],
                openQuestions: [
                    "Does onboarding ship localized for the Japan launch, or English-first?",
                ],
                generatedAt: now - 2 * hour + 43 * 60,
                speakerPerspectives: [
                    SpeakerPerspective(speaker: "Priya", points: [
                        "Onboarding results justify shipping now; keep a rollback flag for one release",
                    ]),
                    SpeakerPerspective(speaker: "Diego", points: [
                        "Split offline mode so the storage layer lands before the freeze",
                        "Defer merge-based conflict resolution until real usage data exists",
                    ]),
                    SpeakerPerspective(speaker: "Mei", points: [
                        "SSO is the single biggest enterprise blocker this quarter",
                    ]),
                ]
            ),
            speakerNames: ["Sam", "Priya", "Mei", "Diego"]
        )

        let designSync = Meeting(
            title: "Design Sync — Onboarding Polish",
            createdAt: now - day - 5 * hour,
            duration: 28 * 60 + 4,
            segments: [
                TranscriptSegment(
                    text: "The permission screen copy still reads like legal. Can we say what the mic is for in one line?",
                    start: 6, end: 14, speaker: 0
                ),
                TranscriptSegment(
                    text: "How about: your audio stays on this iPhone — we only listen while you record.",
                    start: 15, end: 22, speaker: 1
                ),
                TranscriptSegment(
                    text: "That's much better. I'll mock both variants for Thursday's review.",
                    start: 23, end: 29, speaker: 0
                ),
            ],
            summary: MeetingSummary(
                overview: "Reviewed the last rough edges of the onboarding flow; the permission "
                    + "screen gets plainer copy and both variants go to Thursday's design review.",
                keyPoints: [
                    "Permission copy rewritten in plain language",
                    "Progress dots replace the step counter",
                ],
                decisions: ["Present both permission-screen variants on Thursday"],
                actionItems: [
                    ActionItem(task: "Mock both permission-screen variants", owner: "Ana", deadline: "Thursday"),
                ],
                openQuestions: [],
                generatedAt: now - day - 4 * hour
            ),
            speakerNames: ["Ana", "Sam"]
        )

        let oneOnOne = Meeting(
            title: "1:1 — Sam & Priya",
            createdAt: now - day - 8 * hour,
            duration: 22 * 60 + 41,
            segments: [
                TranscriptSegment(
                    text: "Main thing from my side: I'd like to take the lead on the Japan launch checklist.",
                    start: 5, end: 12, speaker: 1
                ),
                TranscriptSegment(
                    text: "You've earned it — let's make it official in the next team meeting.",
                    start: 13, end: 19, speaker: 0
                ),
            ],
            summary: MeetingSummary(
                overview: "Career and project check-in: Priya takes the lead on the Japan "
                    + "launch checklist, announced at the next team meeting.",
                keyPoints: ["Priya leads the Japan launch checklist"],
                decisions: ["Announce the new launch-lead role at the next team meeting"],
                actionItems: [
                    ActionItem(
                        task: "Draft the Japan launch checklist",
                        owner: "Priya", deadline: "Next sprint"
                    ),
                ],
                openQuestions: [],
                generatedAt: now - day - 7 * hour
            ),
            speakerNames: ["Sam", "Priya"]
        )

        let customerCall = Meeting(
            title: "Customer Call — Northwind Logistics",
            createdAt: now - 3 * day - 4 * hour,
            duration: 31 * 60 + 55,
            segments: [
                TranscriptSegment(
                    text: "Our drivers are offline half the day — if notes synced when they're back on "
                        + "Wi-Fi, that alone would sell it internally.",
                    start: 9, end: 19, speaker: 1
                ),
                TranscriptSegment(
                    text: "That's exactly what's on our roadmap for this quarter. I'll share the timeline "
                        + "once the engineering estimate is final.",
                    start: 20, end: 29, speaker: 0
                ),
                TranscriptSegment(
                    text: "Great. Procurement will also ask about single sign-on — that's a hard requirement for us.",
                    start: 30, end: 38, speaker: 1
                ),
            ],
            summary: MeetingSummary(
                overview: "Northwind confirmed offline sync and SSO are their two adoption "
                    + "blockers; both align with the current Q3 plan.",
                keyPoints: [
                    "Drivers are offline for large parts of the day — offline sync is the headline need",
                    "SSO is a hard procurement requirement",
                ],
                decisions: [],
                actionItems: [
                    ActionItem(
                        task: "Send Northwind the offline-sync timeline",
                        owner: "Mei", deadline: ActionItem.notSpecified
                    ),
                ],
                openQuestions: ["Which SSO provider does Northwind use?"],
                generatedAt: now - 3 * day - 3 * hour
            ),
            speakerNames: ["Mei", "Jordan"]
        )

        let allHands = Meeting(
            title: "Engineering All-Hands",
            createdAt: now - 6 * day - 2 * hour,
            duration: 48 * 60 + 12,
            segments: [
                TranscriptSegment(
                    text: "Incident review first: Tuesday's outage was a cache stampede after the deploy. "
                        + "The fix is jittered TTLs, already merged.",
                    start: 14, end: 25, speaker: 0
                ),
                TranscriptSegment(
                    text: "Reminder that the on-call handbook moved — link is pinned in the channel.",
                    start: 26, end: 32, speaker: 1
                ),
            ],
            summary: MeetingSummary(
                overview: "Monthly engineering all-hands: Tuesday's outage post-mortem "
                    + "(cache stampede, fixed with jittered TTLs), on-call handbook moved, "
                    + "and Q3 hiring plan confirmed at two backend roles.",
                keyPoints: [
                    "Outage root cause: cache stampede after deploy; jittered TTLs merged",
                    "On-call handbook relocated — link pinned",
                    "Two backend roles open in Q3",
                ],
                decisions: ["Adopt jittered cache TTLs as the standard pattern"],
                actionItems: [
                    ActionItem(task: "Publish the outage post-mortem", owner: "Lena", deadline: "Friday"),
                ],
                openQuestions: [],
                generatedAt: now - 6 * day - 1 * hour
            ),
            speakerNames: ["Lena", "Marcus"]
        )

        let seeded = [roadmap, designSync, oneOnOne, customerCall, allHands]
        // Pre-stamped so screenshot/demo runs don't fire real FM knowledge extractions.
        for meeting in seeded { meeting.knowledgeExtractedAt = .now }
        return seeded
    }
}
#endif

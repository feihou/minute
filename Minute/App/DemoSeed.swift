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
        for meeting in demoMeetings() { context.insert(meeting) }
        try? context.save()
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

        return [roadmap, designSync, oneOnOne, customerCall, allHands]
    }
}
#endif

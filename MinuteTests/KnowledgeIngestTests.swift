import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeIngestTests {
    /// Containers with the relationship-bearing knowledge schema are retained
    /// for the process lifetime: ModelContainer teardown is not actor-isolated,
    /// and a container deiniting in the background while another test runs
    /// crashes the test host inside SwiftData.framework (signal trap; see
    /// .superpowers/sdd/task-1-report.md). Tests still get a fresh, isolated
    /// container each — they just never tear it down mid-run.
    private static var retainedContainers: [ModelContainer] = []

    @discardableResult
    private static func retain(_ container: ModelContainer) -> ModelContainer {
        retainedContainers.append(container)
        return container
    }

    private func makeContext() throws -> ModelContext {
        try Self.retain(ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )).mainContext
    }

    private func candidate(_ name: String, _ fact: String, kind: EntityKind = .person, quote: String? = "q") -> KnowledgeCandidate {
        KnowledgeCandidate(entityName: name, entityKind: kind, fact: fact, validatedQuote: quote)
    }

    @Test func newEntityFactsAreSuggested() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)

        let result = try KnowledgeIngest.apply([candidate("Sarah", "Sarah leads Atlas")], from: meeting, context: context)

        #expect(result.suggested == 1)
        let entities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
        #expect(entities.count == 1)
        #expect(entities[0].name == "Sarah")
        #expect(entities[0].facts.count == 1)
        #expect(entities[0].facts[0].status == .suggested)
        #expect(entities[0].facts[0].sourceMeetingID == meeting.id)
    }

    @Test func twoCandidatesForOneNewNameShareOneEntity() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads Atlas"), candidate("sarah", "Sarah prefers async")],
            from: meeting, context: context
        )
        #expect(try context.fetch(FetchDescriptor<KnowledgeEntity>()).count == 1)
    }

    @Test func knownEntityHighConfidenceFactIsAutoCaptured() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        context.insert(KnowledgeEntity(name: "Sarah Chen", kind: .person, aliases: ["Sarah"]))
        try context.save()

        let result = try KnowledgeIngest.apply([candidate("sarah", "Sarah prefers async reviews")], from: meeting, context: context)

        #expect(result.autoCaptured == 1)
        let entities = try context.fetch(FetchDescriptor<KnowledgeEntity>())
        #expect(entities.count == 1)  // resolved via alias, no fork
        #expect(entities[0].facts[0].status == .autoCaptured)
    }

    @Test func missingQuoteRoutesToSuggestedEvenOnKnownEntity() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        context.insert(KnowledgeEntity(name: "Sarah", kind: .person))
        try context.save()

        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah is leaving the company", quote: nil)],
            from: meeting, context: context
        )
        #expect(result.suggested == 1)
    }

    @Test func nearDuplicateOfLiveFactIsDropped() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "edited by the user", originalText: "Sarah leads the Atlas redesign",
            status: .approved, sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        ))
        try context.save()

        // Dedup runs on originalText, so the user's edit can't break it.
        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign")],
            from: meeting, context: context
        )
        #expect(result.duplicatesDropped == 1)
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).count == 1)
    }

    @Test func rejectedTombstoneBlocksReextraction() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let tombstone = KnowledgeFact(
            text: "", originalText: "", status: .rejected,
            sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        )
        tombstone.fingerprint = KnowledgeText.fingerprint("Sarah is leaving", entityID: entity.id)
        context.insert(tombstone)
        try context.save()

        let result = try KnowledgeIngest.apply([candidate("Sarah", "Sarah is leaving")], from: meeting, context: context)
        #expect(result.duplicatesDropped == 1)
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).count == 1)  // only the tombstone
    }

    @Test func contradictionBandRoutesToSuggested() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Alice", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "Alice is a senior engineer on Search", originalText: "Alice is a senior engineer on Search",
            status: .approved, sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        ))
        try context.save()

        let result = try KnowledgeIngest.apply(
            [candidate("Alice", "Alice is an engineering manager on Search")],
            from: meeting, context: context
        )
        #expect(result.suggested == 1)
    }

    @Test func crossMeetingParaphraseRoutesToSuggestedNotDropped() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "Sarah leads the Atlas redesign work", originalText: "Sarah leads the Atlas redesign work",
            status: .approved, sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        ))
        try context.save()

        // 5/6 token overlap (~0.83): near-duplicate, but from another
        // meeting — review decides, never a silent drop.
        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign")],
            from: meeting, context: context
        )
        #expect(result.suggested == 1)
        #expect(result.duplicatesDropped == 0)
    }

    @Test func reapplyReplacesSuggestedButKeepsReviewedFacts() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "kept", originalText: "Sarah approved fact",
            status: .approved, sourceMeetingID: meeting.id, capturedAt: .now, entity: entity
        ))
        context.insert(KnowledgeFact(
            text: "stale", originalText: "Sarah stale suggestion",
            status: .suggested, sourceMeetingID: meeting.id, capturedAt: .now, entity: entity
        ))
        try context.save()

        try KnowledgeIngest.apply([candidate("Sarah", "Sarah fresh suggestion", quote: nil)], from: meeting, context: context)

        let facts = try context.fetch(FetchDescriptor<KnowledgeFact>())
        let texts = facts.map(\.originalText).sorted()
        #expect(texts == ["Sarah approved fact", "Sarah fresh suggestion"])
    }

    @Test func reapplyWithSameTextReplacesStaleSuggestionInsteadOfDroppingIt() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "Sarah leads Atlas", originalText: "Sarah leads Atlas",
            status: .suggested, sourceMeetingID: meeting.id, capturedAt: .now, entity: entity
        ))
        try context.save()

        // Re-extraction reproducing the same text must replace, never vanish.
        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads Atlas", quote: nil)],
            from: meeting, context: context
        )

        #expect(result.suggested == 1)
        #expect(result.duplicatesDropped == 0)
        let facts = try context.fetch(FetchDescriptor<KnowledgeFact>())
        #expect(facts.count == 1)
        #expect(facts[0].originalText == "Sarah leads Atlas")
        #expect(facts[0].status == .suggested)
    }

    @Test func ingestInvalidatesSynthesisOnlyForTouchedEntities() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let sarah = KnowledgeEntity(name: "Sarah", kind: .person)
        let bystander = KnowledgeEntity(name: "Atlas", kind: .project)
        context.insert(sarah)
        context.insert(bystander)
        sarah.synthesizedFactCount = 0
        bystander.synthesizedFactCount = 0
        try context.save()

        try KnowledgeIngest.apply([candidate("Sarah", "Sarah leads Atlas")], from: meeting, context: context)

        // A changed fact set can keep the same count, so ingest must clear
        // the marker itself — but only for entities it actually touched.
        #expect(sarah.synthesizedFactCount == nil)
        #expect(bystander.synthesizedFactCount == 0)
    }
    @Test func aRepeatFromAnotherMeetingIsDroppedButRecordedAsCorroboration() throws {
        let context = try makeContext()
        let firstMeeting = Meeting(title: "first")
        let secondMeeting = Meeting(title: "second")
        context.insert(firstMeeting)
        context.insert(secondMeeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let existing = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .approved, sourceMeetingID: firstMeeting.id, capturedAt: .now, entity: entity
        )
        context.insert(existing)
        try context.save()

        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign")],
            from: secondMeeting, context: context
        )

        // Still dropped — the entity page must not show the claim twice.
        #expect(result.duplicatesDropped == 1)
        // But the second meeting is about to be stamped as extracted and will
        // never be read again, so this row has to remember that it says this
        // too. Otherwise deleting the first meeting silently loses the fact.
        #expect(existing.corroboratedByMeetingIDs == [secondMeeting.id])
        #expect(existing.sourceMeetingIDs == [firstMeeting.id, secondMeeting.id])
    }

    @Test func aRepeatWithinTheSameMeetingRecordsNoCorroboration() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let existing = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .approved, sourceMeetingID: meeting.id, capturedAt: .now, entity: entity
        )
        context.insert(existing)
        try context.save()

        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign")],
            from: meeting, context: context
        )

        #expect(result.duplicatesDropped == 1)
        // A meeting cannot corroborate itself.
        #expect(existing.corroboratedByMeetingIDs == nil)
    }

    @Test func aTombstonedClaimRecordsNoCorroboration() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "m")
        context.insert(meeting)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let tombstone = KnowledgeFact(
            text: "", originalText: "", status: .rejected,
            sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        )
        tombstone.fingerprint = KnowledgeText.fingerprint("Sarah is leaving", entityID: entity.id)
        context.insert(tombstone)
        try context.save()

        let result = try KnowledgeIngest.apply([candidate("Sarah", "Sarah is leaving")], from: meeting, context: context)

        #expect(result.duplicatesDropped == 1)
        // A tombstone exists to keep a rejected claim out, not to hold sources —
        // corroborating it would give the rejection a reason to be kept alive.
        #expect(tombstone.corroboratedByMeetingIDs == nil)
    }

    @Test func reExtractionKeepsAFactAnotherMeetingStillStates() throws {
        let context = try makeContext()
        let first = Meeting(title: "first")
        let second = Meeting(title: "second")
        context.insert(first)
        context.insert(second)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        // A suggested row from the first meeting that the second meeting also
        // stated, so dedup dropped the second candidate.
        let existing = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .suggested, sourceMeetingID: first.id, capturedAt: first.createdAt, entity: entity
        )
        existing.addCorroboration(second.id)
        context.insert(existing)
        try context.save()

        // Re-transcribing the first meeting re-extracts it, and this time the
        // model no longer produces that fact.
        _ = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah is on the hiring panel")],
            from: first, context: context
        )

        // Dropping the stale row would lose a claim the second meeting makes,
        // and the second meeting is stamped as extracted, so it is never re-read.
        let texts = try context.fetch(FetchDescriptor<KnowledgeFact>()).map(\.originalText)
        #expect(texts.contains("Sarah leads the Atlas redesign"))
        let carried = try #require(try context.fetch(FetchDescriptor<KnowledgeFact>())
            .first { $0.originalText == "Sarah leads the Atlas redesign" })
        #expect(carried.sourceMeetingID == second.id)
    }

    @Test func reExtractionRevokesACorroborationTheMeetingNoLongerMakes() throws {
        let context = try makeContext()
        let first = Meeting(title: "first")
        let second = Meeting(title: "second")
        context.insert(first)
        context.insert(second)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let fact = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .autoCaptured, sourceMeetingID: first.id, capturedAt: first.createdAt, entity: entity
        )
        fact.addCorroboration(second.id)
        context.insert(fact)
        try context.save()

        // The second meeting is re-transcribed and its new transcript says
        // something else entirely.
        _ = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah is on the hiring panel")],
            from: second, context: context
        )

        // It no longer vouches for the old claim...
        #expect(fact.corroboratedByMeetingIDs == nil)
        // ...so deleting the meeting that does state it takes the fact with it,
        // rather than attributing it to a transcript that no longer supports it.
        #expect(MeetingStore.delete(first, context: context))
        let remaining = try context.fetch(FetchDescriptor<KnowledgeFact>()).map(\.originalText)
        #expect(!remaining.contains("Sarah leads the Atlas redesign"))
    }

    @Test func reExtractionKeepsACorroborationTheMeetingStillMakes() throws {
        let context = try makeContext()
        let first = Meeting(title: "first")
        let second = Meeting(title: "second")
        context.insert(first)
        context.insert(second)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let fact = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .autoCaptured, sourceMeetingID: first.id, capturedAt: first.createdAt, entity: entity
        )
        fact.addCorroboration(second.id)
        context.insert(fact)
        try context.save()

        // Re-transcribed, and it still says the same thing.
        _ = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign")],
            from: second, context: context
        )

        // Cleared and re-added in the same run, so the evidence stands.
        #expect(fact.corroboratedByMeetingIDs == [second.id])
    }

    @Test func aParaphraseAfterACorroborationInTheSameRunIsStillAWithinMeetingRepeat() throws {
        let context = try makeContext()
        let first = Meeting(title: "first")
        let second = Meeting(title: "second")
        context.insert(first)
        context.insert(second)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .approved, sourceMeetingID: first.id, capturedAt: .now, entity: entity
        ))
        try context.save()

        // Adjacent chunks of the second meeting emit the same claim twice: once
        // verbatim, once paraphrased.
        let result = try KnowledgeIngest.apply(
            [
                candidate("Sarah", "Sarah leads the Atlas redesign"),
                candidate("Sarah", "Sarah leads the Atlas redesign work"),
            ],
            from: second, context: context
        )

        // The first corroborates the existing row, which makes the second a
        // repeat of something this meeting already said — not a cross-meeting
        // near-duplicate worth sending to review.
        #expect(result.duplicatesDropped == 2)
        #expect(result.suggested == 0)
        #expect(try context.fetch(FetchDescriptor<KnowledgeFact>()).count == 1)
    }

    @Test func aReorderedRestatementIsDroppedButNotTreatedAsCorroboration() throws {
        let context = try makeContext()
        let first = Meeting(title: "first")
        let second = Meeting(title: "second")
        context.insert(first)
        context.insert(second)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let existing = KnowledgeFact(
            text: "Sarah assigned Alex to Jordan", originalText: "Sarah assigned Alex to Jordan",
            status: .autoCaptured, sourceMeetingID: first.id, capturedAt: .now, entity: entity
        )
        context.insert(existing)
        try context.save()

        // Same tokens, opposite meaning. `normalized` sorts, so dedup cannot
        // tell these apart — that part is existing behaviour.
        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah assigned Jordan to Alex")],
            from: second, context: context
        )

        #expect(result.duplicatesDropped == 1)
        // But the second meeting did not say what the first said, so it must
        // not end up owning the first meeting's claim when that meeting goes.
        #expect(existing.corroboratedByMeetingIDs == nil)
    }

    @Test func anUngroundedRestatementIsDroppedButNotTreatedAsCorroboration() throws {
        let context = try makeContext()
        let first = Meeting(title: "first")
        let second = Meeting(title: "second")
        context.insert(first)
        context.insert(second)
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        let existing = KnowledgeFact(
            text: "Sarah leads the Atlas redesign", originalText: "Sarah leads the Atlas redesign",
            status: .autoCaptured, sourceMeetingID: first.id, capturedAt: .now, entity: entity
        )
        context.insert(existing)
        try context.save()

        // No quote survived validation against this transcript, which is what
        // would normally hold the candidate back as a draft.
        let result = try KnowledgeIngest.apply(
            [candidate("Sarah", "Sarah leads the Atlas redesign", quote: nil)],
            from: second, context: context
        )

        #expect(result.duplicatesDropped == 1)
        // Corroboration would let this meeting inherit an auto-captured fact on
        // evidence too weak to have captured it in the first place.
        #expect(existing.corroboratedByMeetingIDs == nil)
    }

}

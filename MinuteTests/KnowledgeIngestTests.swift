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
}

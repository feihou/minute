import Foundation
import SwiftData
import Testing
@testable import Minute

/// Deleting a meeting must take the knowledge extracted from it. Facts key off
/// a plain `sourceMeetingID` rather than a SwiftData relationship, so nothing
/// cascades on its own — these tests pin the explicit cleanup.
@MainActor
struct KnowledgeDeletionTests {
    /// Containers with the relationship-bearing knowledge schema are retained
    /// for the process lifetime: ModelContainer teardown is not actor-isolated,
    /// and a container deiniting in the background while another test runs
    /// crashes the test host inside SwiftData.framework.
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

    @discardableResult
    private func addFact(
        _ text: String,
        to entity: KnowledgeEntity,
        from meeting: Meeting,
        status: FactStatus = .autoCaptured,
        context: ModelContext
    ) -> KnowledgeFact {
        let fact = KnowledgeFact(
            text: text,
            originalText: text,
            status: status,
            sourceMeetingID: meeting.id,
            capturedAt: meeting.createdAt,
            entity: entity
        )
        context.insert(fact)
        return fact
    }

    private func facts(in context: ModelContext) throws -> [KnowledgeFact] {
        try context.fetch(FetchDescriptor<KnowledgeFact>())
    }

    private func entities(in context: ModelContext) throws -> [KnowledgeEntity] {
        try context.fetch(FetchDescriptor<KnowledgeEntity>())
    }

    // MARK: - Deleting a meeting

    @Test func deletingAMeetingRemovesTheFactsItProduced() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Roadmap")
        context.insert(meeting)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        addFact("Owns the Japan launch", to: priya, from: meeting, context: context)
        try context.save()
        #expect(try facts(in: context).count == 1)

        #expect(MeetingStore.delete(meeting, context: context))

        #expect(try facts(in: context).isEmpty)
    }

    @Test func factsFromOtherMeetingsAreUntouched() throws {
        let context = try makeContext()
        let deleted = Meeting(title: "Deleted")
        let kept = Meeting(title: "Kept")
        context.insert(deleted)
        context.insert(kept)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        addFact("From the deleted meeting", to: priya, from: deleted, context: context)
        addFact("From the kept meeting", to: priya, from: kept, context: context)
        try context.save()

        #expect(MeetingStore.delete(deleted, context: context))

        let remaining = try facts(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.text == "From the kept meeting")
        // The entity still has something to say, so it stays.
        #expect(try entities(in: context).count == 1)
    }

    @Test func anEntityLeftWithNothingIsRemoved() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Only source")
        context.insert(meeting)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        addFact("Owns the Japan launch", to: priya, from: meeting, context: context)
        try context.save()

        #expect(MeetingStore.delete(meeting, context: context))

        // The name itself was learned from the deleted meeting, so keeping an
        // empty "Priya" page would retain meeting-derived personal data.
        #expect(try entities(in: context).isEmpty)
    }

    @Test func aSurvivingEntityLosesTheNarrativeWrittenFromDeletedFacts() throws {
        let context = try makeContext()
        let deleted = Meeting(title: "Deleted")
        let kept = Meeting(title: "Kept")
        context.insert(deleted)
        context.insert(kept)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        priya.synthesis = "Priya owns the Japan launch and the Q3 scope."
        priya.synthesizedFactCount = 2
        context.insert(priya)
        addFact("Owns the Japan launch", to: priya, from: deleted, context: context)
        addFact("Owns the Q3 scope", to: priya, from: kept, context: context)
        try context.save()

        #expect(MeetingStore.delete(deleted, context: context))

        let survivor = try #require(try entities(in: context).first)
        // The narrative was written over a fact that no longer exists, so it
        // could still describe the deleted meeting. It must be regenerated.
        #expect(survivor.synthesis == nil)
        #expect(survivor.synthesizedFactCount == nil)
    }

    @Test func aMergeTombstoneSurvivesWhileItsDestinationDoes() throws {
        let context = try makeContext()
        let deleted = Meeting(title: "Deleted")
        let kept = Meeting(title: "Kept")
        context.insert(deleted)
        context.insert(kept)
        let canonical = KnowledgeEntity(name: "Priya Sharma", kind: .person)
        context.insert(canonical)
        let merged = KnowledgeEntity(name: "Priya", kind: .person, redirectTo: canonical.id)
        context.insert(merged)
        addFact("Owns the Japan launch", to: merged, from: deleted, context: context)
        addFact("Owns the Q3 scope", to: canonical, from: kept, context: context)
        try context.save()

        #expect(MeetingStore.delete(deleted, context: context))

        // The tombstone has lost its own facts but still points somewhere real,
        // so it stays and merge resolution keeps working.
        let survivors = try entities(in: context)
        #expect(survivors.count == 2)
        #expect(survivors.contains { $0.redirectTo == canonical.id })
    }

    @Test func aMergeTombstoneIsRemovedWithItsDestination() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Only source")
        context.insert(meeting)
        let canonical = KnowledgeEntity(name: "Priya Sharma", kind: .person)
        context.insert(canonical)
        let merged = KnowledgeEntity(name: "Priya", kind: .person, redirectTo: canonical.id)
        context.insert(merged)
        addFact("Owns the Japan launch", to: merged, from: meeting, context: context)
        addFact("Owns the Q3 scope", to: canonical, from: meeting, context: context)
        try context.save()

        #expect(MeetingStore.delete(meeting, context: context))

        // Keeping the tombstone once its destination is gone would leave a
        // redirect to nothing: resolution falls back to the tombstone itself,
        // and new facts land on an entity every Brain surface filters out.
        #expect(try entities(in: context).isEmpty)
    }

    @Test func aMergeTombstoneChainIsRemovedWithItsFinalDestination() throws {
        let context = try makeContext()
        let meeting = Meeting(title: "Only source")
        context.insert(meeting)
        let canonical = KnowledgeEntity(name: "Priya Sharma", kind: .person)
        context.insert(canonical)
        let middle = KnowledgeEntity(name: "P. Sharma", kind: .person, redirectTo: canonical.id)
        context.insert(middle)
        let oldest = KnowledgeEntity(name: "Priya", kind: .person, redirectTo: middle.id)
        context.insert(oldest)
        addFact("Owns the Q3 scope", to: canonical, from: meeting, context: context)
        try context.save()

        #expect(MeetingStore.delete(meeting, context: context))

        // A winner can itself have been merged away, so the walk has to follow
        // the whole chain rather than one hop.
        #expect(try entities(in: context).isEmpty)
    }

    @Test func sweepLeavesAnEntityAloneWhenItsOnlyOrphanIsARejectedTombstone() throws {
        let context = try makeContext()
        let live = Meeting(title: "Live")
        context.insert(live)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        addFact("Still sourced", to: priya, from: live, context: context)
        // Retained on purpose: the fingerprint stops a rejected claim coming
        // back from another meeting. Its source meeting is long gone, so every
        // sweep re-selects it.
        let tombstone = KnowledgeFact(
            text: "",
            originalText: "",
            status: .rejected,
            sourceMeetingID: UUID(),
            capturedAt: .now,
            entity: priya
        )
        context.insert(tombstone)
        priya.synthesis = "Priya is still around."
        priya.synthesizedFactCount = 1
        try context.save()

        // Twice: a re-touch would show up as the narrative being discarded.
        #expect(KnowledgeStore.sweepOrphanedFacts(liveMeetingIDs: [live.id], context: context))
        #expect(KnowledgeStore.sweepOrphanedFacts(liveMeetingIDs: [live.id], context: context))

        let survivor = try #require(try entities(in: context).first)
        #expect(survivor.synthesis == "Priya is still around.")
        #expect(survivor.synthesizedFactCount == 1)
        // The tombstone itself is kept.
        #expect(try facts(in: context).count == 2)
    }

    // MARK: - Facts several meetings support

    @Test func aFactAnotherMeetingRestatedIsKeptAndRepointed() throws {
        let context = try makeContext()
        let first = Meeting(title: "First", createdAt: .now.addingTimeInterval(-7200))
        let second = Meeting(title: "Second")
        context.insert(first)
        context.insert(second)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        let fact = addFact("Owns the Japan launch", to: priya, from: first, context: context)
        // What KnowledgeIngest records when the second meeting says the same
        // thing: the candidate is dropped and only this row survives.
        fact.addCorroboration(second.id)
        try context.save()

        #expect(MeetingStore.delete(first, context: context))

        // The second meeting still says this and is stamped as extracted, so it
        // will never be re-read — dropping the row would lose the claim.
        let survivor = try #require(try facts(in: context).first)
        #expect(survivor.text == "Owns the Japan launch")
        #expect(survivor.sourceMeetingID == second.id)
        #expect(survivor.capturedAt == second.createdAt)
        #expect(survivor.corroboratedByMeetingIDs == nil)
        #expect(try entities(in: context).count == 1)
    }

    @Test func aRestatedFactGoesOnceItsLastMeetingDoes() throws {
        let context = try makeContext()
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        context.insert(first)
        context.insert(second)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        let fact = addFact("Owns the Japan launch", to: priya, from: first, context: context)
        fact.addCorroboration(second.id)
        try context.save()

        #expect(MeetingStore.delete(first, context: context))
        #expect(try facts(in: context).count == 1)
        #expect(MeetingStore.delete(second, context: context))

        #expect(try facts(in: context).isEmpty)
        #expect(try entities(in: context).isEmpty)
    }

    @Test func theSweepRescuesARestatedFactRatherThanTreatingItAsOrphaned() throws {
        let context = try makeContext()
        let live = Meeting(title: "Live")
        context.insert(live)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        // Its original meeting was deleted by a build without the purge, but a
        // meeting that still exists restated it.
        let fact = KnowledgeFact(
            text: "Owns the Japan launch",
            originalText: "Owns the Japan launch",
            status: .autoCaptured,
            sourceMeetingID: UUID(),
            capturedAt: .now.addingTimeInterval(-7200),
            entity: priya
        )
        fact.addCorroboration(live.id)
        context.insert(fact)
        try context.save()

        #expect(KnowledgeStore.sweepOrphanedFacts(liveMeetingIDs: [live.id], context: context))

        let survivor = try #require(try facts(in: context).first)
        #expect(survivor.sourceMeetingID == live.id)
        #expect(try entities(in: context).count == 1)
    }

    // MARK: - Sweep (upgrade path and failed purges)

    @Test func sweepRemovesFactsWhoseMeetingIsAlreadyGone() throws {
        let context = try makeContext()
        let live = Meeting(title: "Live")
        context.insert(live)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        addFact("Still sourced", to: priya, from: live, context: context)
        // A meeting deleted by a build that had no purge — the fact it left
        // behind points at a UUID no meeting has.
        let orphan = KnowledgeFact(
            text: "Orphaned by an older version",
            originalText: "Orphaned by an older version",
            status: .autoCaptured,
            sourceMeetingID: UUID(),
            capturedAt: .now,
            entity: priya
        )
        context.insert(orphan)
        try context.save()
        #expect(try facts(in: context).count == 2)

        #expect(KnowledgeStore.sweepOrphanedFacts(liveMeetingIDs: [live.id], context: context))

        let remaining = try facts(in: context)
        #expect(remaining.count == 1)
        #expect(remaining.first?.text == "Still sourced")
    }

    @Test func sweepKeepsEverythingWhenNoMeetingIsMissing() throws {
        let context = try makeContext()
        let live = Meeting(title: "Live")
        context.insert(live)
        let priya = KnowledgeEntity(name: "Priya", kind: .person)
        context.insert(priya)
        addFact("Still sourced", to: priya, from: live, context: context)
        priya.synthesis = "Priya is still around."
        priya.synthesizedFactCount = 1
        try context.save()

        #expect(KnowledgeStore.sweepOrphanedFacts(liveMeetingIDs: [live.id], context: context))

        #expect(try facts(in: context).count == 1)
        // A no-op sweep must not invalidate a perfectly current narrative.
        #expect(try entities(in: context).first?.synthesis == "Priya is still around.")
    }

    @Test func deleteAllMeetingsEmptiesTheKnowledgeBase() throws {
        let context = try makeContext()
        let meetings = (0..<3).map { Meeting(title: "Meeting \($0)") }
        meetings.forEach { context.insert($0) }
        let people = ["Priya", "Atlas", "Onboarding"].map { KnowledgeEntity(name: $0, kind: .person) }
        people.forEach { context.insert($0) }
        for (index, entity) in people.enumerated() {
            addFact("Fact \(index)", to: entity, from: meetings[index], context: context)
        }
        try context.save()

        // Settings' Delete All Meetings is this loop.
        for meeting in meetings {
            #expect(MeetingStore.delete(meeting, context: context))
        }

        #expect(try facts(in: context).isEmpty)
        #expect(try entities(in: context).isEmpty)
    }
}

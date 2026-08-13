// MinuteTests/KnowledgeBriefTests.swift
import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct KnowledgeBriefTests {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self, KnowledgeEntity.self, KnowledgeFact.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        Self.retainedContainers.append(container)
        return container.mainContext
    }

    @Test func matchesSpeakersToPeopleByNormalizedNameOrAlias() throws {
        let context = try makeContext()
        let sarah = KnowledgeEntity(name: "Sarah Chen", kind: .person, aliases: ["Sarah"])
        let atlas = KnowledgeEntity(name: "Atlas", kind: .project)
        let merged = KnowledgeEntity(name: "Bob", kind: .person)
        merged.redirectTo = UUID()
        for entity in [sarah, atlas, merged] { context.insert(entity) }
        try context.save()
        let all = try context.fetch(FetchDescriptor<KnowledgeEntity>())

        // Alias match, case/diacritic-insensitive.
        #expect(KnowledgeBrief.matchedEntities(speakerNames: ["sárah", "Diego"], entities: all).map(\.name) == ["Sarah Chen"])
        // Projects never match speakers; redirected entities never match.
        #expect(KnowledgeBrief.matchedEntities(speakerNames: ["Atlas", "Bob"], entities: all).isEmpty)
        #expect(KnowledgeBrief.matchedEntities(speakerNames: nil, entities: all).isEmpty)
        #expect(KnowledgeBrief.matchedEntities(speakerNames: ["", " "], entities: all).isEmpty)
    }

    @Test func recentlyLearnedIsAutoCapturedOnlyNewestFirstCapped() throws {
        let context = try makeContext()
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        for index in 0..<7 {
            let fact = KnowledgeFact(
                text: "auto \(index)", originalText: "auto \(index)", status: .autoCaptured,
                sourceMeetingID: UUID(), capturedAt: .now.addingTimeInterval(Double(-index) * 60), entity: entity,
                createdAt: .now.addingTimeInterval(Double(-index) * 60)
            )
            context.insert(fact)
        }
        context.insert(KnowledgeFact(
            text: "draft", originalText: "draft", status: .suggested,
            sourceMeetingID: UUID(), capturedAt: .now, entity: entity
        ))
        // An m1-era row without createdAt still orders via capturedAt.
        let legacy = KnowledgeFact(
            text: "legacy", originalText: "legacy", status: .autoCaptured,
            sourceMeetingID: UUID(), capturedAt: .now.addingTimeInterval(30), entity: entity
        )
        legacy.createdAt = nil
        context.insert(legacy)
        try context.save()

        let recent = KnowledgeBrief.recentlyLearned(from: try context.fetch(FetchDescriptor<KnowledgeEntity>()), limit: 5)

        #expect(recent.count == 5)
        #expect(recent.first?.text == "legacy")            // newest by fallback capturedAt
        #expect(!recent.map(\.text).contains("draft"))     // suggested excluded
    }

    @Test func briefExcludesFactsFromTheMeetingBeingViewed() throws {
        let context = try makeContext()
        let meetingID = UUID()
        let entity = KnowledgeEntity(name: "Sarah", kind: .person)
        context.insert(entity)
        context.insert(KnowledgeFact(
            text: "from this meeting", originalText: "from this meeting", status: .autoCaptured,
            sourceMeetingID: meetingID, capturedAt: .now, entity: entity
        ))
        context.insert(KnowledgeFact(
            text: "from before", originalText: "from before", status: .autoCaptured,
            sourceMeetingID: UUID(), capturedAt: .now.addingTimeInterval(-3600), entity: entity
        ))
        try context.save()

        let facts = KnowledgeBrief.briefFacts(for: entity, excludingMeetingID: meetingID)

        #expect(facts.map(\.text) == ["from before"])
    }
}

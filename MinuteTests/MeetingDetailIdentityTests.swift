import Foundation
import SwiftData
import Testing
@testable import Minute

@MainActor
struct MeetingDetailIdentityTests {
    /// A context does not keep its container alive; letting one go traps on the
    /// next insert. Held for the process, as the other SwiftData suites do.
    private static var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: MeetingStore.modelConfiguration(inMemory: true)
        )
        Self.retainedContainers.append(container)
        return container.mainContext
    }

    private func savedMeeting(_ title: String, context: ModelContext) throws -> Meeting {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        try context.save()
        return meeting
    }

    // MARK: - Is the meeting gone?

    @Test func aStoredMeetingIsNotGone() throws {
        let context = try makeContext()
        let meeting = try savedMeeting("Present", context: context)

        #expect(!meeting.isGone)
    }

    @Test func aPendingDeleteCountsAsGone() throws {
        let context = try makeContext()
        let meeting = try savedMeeting("Pending Delete", context: context)

        context.delete(meeting)

        #expect(meeting.isGone)
    }

    /// The case a plain `isDeleted` check misses, and the only one a second
    /// navigation stack ever sees: `MeetingStore.delete` saves before it
    /// returns, and SwiftData clears `isDeleted` again once the delete commits,
    /// leaving the object behind with its last-known values.
    @Test func aCommittedDeleteCountsAsGone() throws {
        let context = try makeContext()
        let meeting = try savedMeeting("Deleted From The Brain Tab", context: context)

        #expect(MeetingStore.delete(meeting, context: context))

        #expect(!meeting.isDeleted, "SwiftData clears isDeleted once the delete commits")
        #expect(meeting.isGone)
    }

    // MARK: - The detail view's identity

    /// F22: two meetings must key two different detail views, or replacing the
    /// destination in place — a widget link arriving while a detail is up —
    /// reuses the previous meeting's player, tab, and auto-summary state.
    @Test func liveMeetingsKeyOnTheirOwnIdentifiers() throws {
        let context = try makeContext()
        let first = try savedMeeting("First", context: context)
        let second = try savedMeeting("Second", context: context)

        #expect(MeetingDetailIdentity.key(for: first) == first.id)
        #expect(MeetingDetailIdentity.key(for: second) == second.id)
        #expect(MeetingDetailIdentity.key(for: first) != MeetingDetailIdentity.key(for: second))
    }

    /// F38: the destination closure re-runs whenever the list's query
    /// invalidates, and deleting the meeting from the Brain tab's stack does
    /// exactly that while this stack still holds it. `id` keeps answering with
    /// a stale value there, so the key has to come from somewhere else.
    @Test func aDeletedMeetingHasNoIdentity() throws {
        let context = try makeContext()
        let meeting = try savedMeeting("Deleted From The Brain Tab", context: context)

        #expect(MeetingStore.delete(meeting, context: context))

        #expect(MeetingDetailIdentity.key(for: meeting) == nil)
    }

    @Test func aPendingDeleteAlsoDropsTheIdentity() throws {
        let context = try makeContext()
        let meeting = try savedMeeting("Pending Delete", context: context)

        context.delete(meeting)

        #expect(MeetingDetailIdentity.key(for: meeting) == nil)
    }
}

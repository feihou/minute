import SwiftData
import SwiftUI

/// Pure grouping for the Brain tab — testable without a view.
enum BrainSections {
    /// The tab's grouped entities. A named type instead of a wide tuple
    /// (SwiftLint large_tuple).
    struct Groups {
        var me: KnowledgeEntity?
        var people: [KnowledgeEntity]
        var projects: [KnowledgeEntity]
        var topics: [KnowledgeEntity]
    }

    static func grouped(_ entities: [KnowledgeEntity]) -> Groups {
        let live = entities.filter { $0.redirectTo == nil }
        func section(_ kind: EntityKind) -> [KnowledgeEntity] {
            live.filter { $0.kind == kind && !$0.visibleFacts.isEmpty }
                .sorted { ($0.visibleFacts.first?.capturedAt ?? .distantPast) > ($1.visibleFacts.first?.capturedAt ?? .distantPast) }
        }
        return Groups(
            me: live.first { $0.kind == .me },
            people: section(.person),
            projects: section(.project),
            topics: section(.topic)
        )
    }
}

/// The knowledge layer's home: what Minute knows about you, your people,
/// projects, and topics — filled in automatically, on device. Read-only in
/// m2a; curation (review, merge, forget) is m2b.
struct BrainView: View {
    @Environment(KnowledgeCatchUp.self) private var catchUp
    @Environment(\.modelContext) private var context
    @Query private var entities: [KnowledgeEntity]

    private var sections: BrainSections.Groups {
        BrainSections.grouped(entities)
    }

    private var isEmpty: Bool {
        sections.me == nil && sections.people.isEmpty && sections.projects.isEmpty && sections.topics.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty, let unavailable = KnowledgeExtractionService.availabilityMessage {
                    ContentUnavailableView {
                        Label("Brain Needs Apple Intelligence", systemImage: "brain.head.profile")
                    } description: {
                        Text(unavailable)
                    }
                } else if isEmpty {
                    emptyState
                } else {
                    brainList
                }
            }
            .navigationTitle("Brain")
            .navigationDestination(for: KnowledgeEntity.self) { entity in
                EntityDetailView(entity: entity)
            }
            // Opening the tab is the moment the user wants to see the latest
            // — refresh the pending count and pick up anything a save left
            // unread (deleting a meeting, for instance, never nudges).
            .task { catchUp.nudge(context: context) }
        }
    }

    private var brainList: some View {
        List {
            catchUpStatus

            let recent = KnowledgeBrief.recentlyLearned(from: entities)
            if !recent.isEmpty {
                Section {
                    ForEach(recent) { fact in
                        if let entity = fact.entity {
                            NavigationLink(value: entity) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(fact.text)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Text(entity.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .modifier(BrainRowInsets())
                        }
                    }
                } header: {
                    brainHeader("Recently Learned")
                }
            }
            if let me = sections.me {
                Section {
                    entityRow(me)
                } header: {
                    brainHeader("You")
                }
            }
            entitySection("People", entities: sections.people)
            entitySection("Projects", entities: sections.projects)
            entitySection("Topics", entities: sections.topics)

            Section {
                Text("Built on this iPhone — stays here unless you opt into iCloud backup.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .modifier(BrainRowInsets())
            }
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    @ViewBuilder private var catchUpStatus: some View {
        if catchUp.isWorking {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Catching up on \(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s")…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .modifier(BrainRowInsets())
            }
            .listRowSeparator(.hidden)
        } else if catchUp.pendingCount > 0 {
            // Pending but idle (skip-listed failures, model not ready):
            // say so without pretending anything is running.
            Section {
                Label("\(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s") still to read — Minute catches up while it's open.",
                      systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .modifier(BrainRowInsets())
            }
            .listRowSeparator(.hidden)
        }
        // Its own `if`, not another branch: refused chunks and pending
        // meetings are separate facts, and a meeting can be skip-listed while
        // the loop is working on the next one. The wording stays out of the
        // pending row's way — that row is directly above, promising Minute
        // catches up while the app is open, and "will be retried next time
        // Minute opens" flatly contradicted it about the same meeting.
        if !catchUp.skippedChunksByMeeting.isEmpty {
            let parts = catchUp.skippedChunksByMeeting.values.reduce(0, +)
            Section {
                Label("\(parts) part\(parts == 1 ? "" : "s") of your meetings couldn't be read yet — Minute will try them again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .modifier(BrainRowInsets())
            }
            .listRowSeparator(.hidden)
        }
    }

    private func brainHeader(_ title: String) -> some View {
        SectionHeading(title)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .modifier(BrainRowInsets())
    }

    @ViewBuilder
    private func entitySection(_ title: String, entities: [KnowledgeEntity]) -> some View {
        if !entities.isEmpty {
            Section {
                ForEach(entities) { entityRow($0) }
            } header: {
                brainHeader(title)
            }
        }
    }

    private func entityRow(_ entity: KnowledgeEntity) -> some View {
        NavigationLink(value: entity) {
            HStack(alignment: .firstTextBaseline) {
                Text(entity.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                let count = entity.visibleFacts.count
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) fact\(count == 1 ? "" : "s")")
            }
        }
        .modifier(BrainRowInsets())
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.brand)
                        .frame(width: 76, height: 76)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 8)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 26)

                Text("Minute is building\nyour second brain")
                    .font(.largeTitle.bold())
                    .lineSpacing(2)
                    .padding(.bottom, 10)
                Text("As you record meetings, on-device intelligence remembers the people, projects, and decisions that matter. It stays on this iPhone unless you opt into iCloud backup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // A first-run user's earliest visit likely lands mid-extraction —
                // show that the brain is being built right now, or that work is
                // waiting (warm phone, model not ready) so the screen never looks
                // dead while meetings sit unread.
                if catchUp.isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your \(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s") now…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 28)
                } else if catchUp.pendingCount > 0 {
                    Label("\(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s") still to read — Minute catches up while it's open.",
                          systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }
}

/// Shared row metrics for the Brain list — text lines up with the section
/// headings above it instead of sitting on the default inset.
private struct BrainRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowInsets(
            EdgeInsets(top: 10, leading: Layout.margin, bottom: 10, trailing: Layout.margin)
        )
    }
}

/// One entity's page: the synthesis narrative on top (the system saying
/// something ABOUT the entity), dated facts with their source meeting
/// underneath — the receipts under the story (spec §6). Read-only in m2a.
struct EntityDetailView: View {
    /// Re-fires the synthesis refresh when facts arrive OR when ingest
    /// invalidates the marker without changing the count (a same-count
    /// re-extraction while this page is open).
    private struct SynthesisTaskID: Equatable {
        let factCount: Int
        let marker: Int?
    }

    @Environment(\.modelContext) private var context
    @Bindable var entity: KnowledgeEntity
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @State private var synthesisRefreshFailed = false

    private var meetingsByID: [UUID: Meeting] {
        Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
    }

    var body: some View {
        Group {
            if entity.isGone {
                // A normal path, not a corner: ingest deletes an entity the
                // moment its last fact goes (a source meeting deleted, a
                // re-extraction that drops it), and renaming a speaker retires
                // the "Speaker 2" page the user may still be looking at.
                // `isGone`, not `isDeleted` — by the time this page redraws the
                // delete has committed and `isDeleted` reads false again, so
                // the page below would render an entity that is no longer
                // there. Reading any other property of a detached model is
                // unsafe, so this branch comes before the page and the title.
                ContentUnavailableView {
                    Label("No Longer Known", systemImage: "brain.head.profile")
                } description: {
                    Text("Everything Minute knew here came from a meeting you deleted.")
                }
            } else {
                page
            }
        }
        .navigationTitle(entity.isGone ? "" : entity.name)
        .navigationBarTitleDisplayMode(.large)
        // Re-run when facts arrive while the page is open (catch-up loop).
        .task(id: synthesisTaskID) {
            guard !entity.isGone else { return }
            synthesisRefreshFailed = false
            synthesisRefreshFailed = await !KnowledgeSynthesisService.refreshIfStale(entity, context: context)
        }
    }

    /// Nil once the entity is gone, so the refresh below never runs against a
    /// deleted model.
    private var synthesisTaskID: SynthesisTaskID? {
        guard !entity.isGone else { return nil }
        return SynthesisTaskID(factCount: entity.settledFacts.count, marker: entity.synthesizedFactCount)
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // No masthead here: unlike a meeting title, an entity name is
                // not editable, so the navigation bar's own large title says it
                // once and collapses on scroll.
                synthesisSection
                factsSection

                Text("Learned from your meetings, entirely on this iPhone. Tap a source to open the meeting.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.margin)
            .padding(.bottom, 56)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder private var synthesisSection: some View {
        if let synthesis = entity.synthesis, !synthesis.isEmpty {
            VStack(alignment: .leading, spacing: Layout.headingGap) {
                SectionHeading(entity.kind == .me ? "About You" : "What Minute Knows")
                Text(synthesis)
                    .lineSpacing(4)
            }
            .padding(.top, 4)
        } else if KnowledgeSynthesisService.isStale(entity), KnowledgeSynthesisService.availabilityMessage == nil,
            !synthesisRefreshFailed {
            HStack(spacing: 12) {
                ProgressView()
                Text("Writing the summary on device…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Layout.sectionGap)
        }
    }

    @ViewBuilder private var factsSection: some View {
        SectionHeading("Facts")
            .padding(.top, Layout.sectionGap)
            .padding(.bottom, Layout.headingGap)
        // Rows sit directly in the enclosing LazyVStack. A wrapper VStack would
        // make the whole section one child and build every row up front, which
        // a person or project that has accumulated years of facts would feel.
        ForEach(Array(entity.visibleFacts.enumerated()), id: \.element.id) { index, fact in
            factRow(fact)
                .padding(.top, index == 0 ? 0 : 18)
        }
    }

    private func factRow(_ fact: KnowledgeFact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fact.text)
                Spacer(minLength: 0)
                if fact.status == .suggested {
                    statusTag("Draft", tint: .orange)
                } else if fact.status == .autoCaptured {
                    statusTag("Auto", tint: .secondary)
                }
            }
            // Date and source read as a citation under the claim rather than
            // as two more pills.
            HStack(spacing: 6) {
                Text(fact.capturedAt.formatted(date: .abbreviated, time: .omitted))
                if let source = fact.newestSource, let meeting = meetingsByID[source.meetingID] {
                    Text("·")
                    NavigationLink {
                        MeetingDetailView(meeting: meeting)
                    } label: {
                        Text(meeting.title)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                // A deleted source meeting simply shows no link — the fact
                // survives its source (spec §6: sources tolerate deletion).
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func statusTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(tint)
            .accessibilityLabel(text)
    }
}

#if DEBUG
#Preview {
    BrainView()
        .modelContainer(MeetingStore.previewContainer())
        .environment(KnowledgeCatchUp())
}
#endif

import SwiftData
import SwiftUI

/// Pure grouping for the Brain tab — testable without a view.
enum BrainSections {
    static func grouped(
        _ entities: [KnowledgeEntity]
    ) -> (me: KnowledgeEntity?, people: [KnowledgeEntity], projects: [KnowledgeEntity], topics: [KnowledgeEntity]) {
        let live = entities.filter { $0.redirectTo == nil }
        func section(_ kind: EntityKind) -> [KnowledgeEntity] {
            live.filter { $0.kind == kind && !$0.visibleFacts.isEmpty }
                .sorted { ($0.visibleFacts.first?.capturedAt ?? .distantPast) > ($1.visibleFacts.first?.capturedAt ?? .distantPast) }
        }
        return (live.first { $0.kind == .me }, section(.person), section(.project), section(.topic))
    }
}

/// The knowledge layer's home: what Minute knows about you, your people,
/// projects, and topics — filled in automatically, on device. Read-only in
/// m2a; curation (review, merge, forget) is m2b.
struct BrainView: View {
    @Environment(KnowledgeCatchUp.self) private var catchUp
    @Query private var entities: [KnowledgeEntity]

    private var sections: (me: KnowledgeEntity?, people: [KnowledgeEntity], projects: [KnowledgeEntity], topics: [KnowledgeEntity]) {
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
        }
    }

    private var brainList: some View {
        List {
            if catchUp.pendingCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Catching up on \(catchUp.pendingCount) meeting\(catchUp.pendingCount == 1 ? "" : "s")…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let me = sections.me {
                Section("You") { entityRow(me) }
            }
            entitySection("People", systemImage: "person.2", entities: sections.people)
            entitySection("Projects", systemImage: "folder", entities: sections.projects)
            entitySection("Topics", systemImage: "tag", entities: sections.topics)
            Section {
            } footer: {
                Label("On-device only — never leaves your iPhone.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func entitySection(_ title: String, systemImage: String, entities: [KnowledgeEntity]) -> some View {
        if !entities.isEmpty {
            Section {
                ForEach(entities) { entityRow($0) }
            } header: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private func entityRow(_ entity: KnowledgeEntity) -> some View {
        NavigationLink(value: entity) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entity.name)
                    .font(.headline)
                    .lineLimit(1)
                let count = entity.visibleFacts.count
                Text("\(count) fact\(count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.brand)
                        .frame(width: 96, height: 96)
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 18, y: 8)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 24)

                Text("Minute is building your second brain")
                    .font(.title2.bold())
                    .padding(.bottom, 6)
                Text("As you record meetings, on-device intelligence remembers the people, projects, and decisions that matter — and it all stays on this iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }
}

/// Minimal entity page so the Brain tab navigates end-to-end; Task 4
/// replaces this body with synthesis, source chips, and draft styling.
struct EntityDetailView: View {
    @Bindable var entity: KnowledgeEntity

    var body: some View {
        List {
            ForEach(entity.visibleFacts) { fact in
                Text(fact.text)
            }
        }
        .navigationTitle(entity.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    BrainView()
        .modelContainer(MeetingStore.previewContainer())
        .environment(KnowledgeCatchUp())
}
#endif

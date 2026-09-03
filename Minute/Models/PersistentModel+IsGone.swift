import SwiftData

extension PersistentModel {
    /// Whether this model is no longer in the store.
    ///
    /// `isDeleted` alone does not answer that: SwiftData reports it only while
    /// the delete is still pending and clears it again once the save commits,
    /// detaching the object but leaving it alive with its last-known values.
    /// The committed case is the one that reaches anything outliving the
    /// delete — a view in the stack that did not do the deleting, or a loop
    /// awaiting a model call — so both halves have to be asked about, or a
    /// stale-object guard silently passes on every object it exists to catch.
    var isGone: Bool {
        isDeleted || modelContext == nil
    }
}

import CryptoKit
import Foundation

/// Pure text utilities under the knowledge layer's resolution and dedup.
/// All matching runs on normalized forms so model spelling variance
/// ("Bob" / "bob" / "Bób") never fragments entities or duplicates facts.
enum KnowledgeText {
    /// Canonical comparison form: casefolded, diacritics stripped,
    /// punctuation dropped, tokens sorted — "Zhang, Wei" == "wei zhang".
    /// ponytail: token-sort makes "Alice leads Atlas"/"Atlas leads Alice"
    /// collide; word-order-aware hashing if that ever bites.
    static func normalized(_ text: String) -> String {
        tokens(text).sorted().joined(separator: " ")
    }

    /// Jaccard similarity of normalized token sets, 0...1.
    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let ta = Set(tokens(a))
        let tb = Set(tokens(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    /// Whether `quote` appears in `transcript`, ignoring case, diacritics,
    /// punctuation, and whitespace runs — the sourceQuote validation gate.
    static func contains(transcript: String, quote: String) -> Bool {
        let q = tokens(quote).joined(separator: " ")
        guard !q.isEmpty else { return false }
        return tokens(transcript).joined(separator: " ").contains(q)
    }

    /// Salted SHA-256 of the normalized text + entity ID — all a rejected
    /// tombstone retains. Salt is per-install so fingerprints can't be
    /// dictionary-tested against another device's store.
    static func fingerprint(_ text: String, entityID: UUID) -> String {
        let payload = "\(salt)|\(normalized(text))|\(entityID.uuidString)"
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Order-preserving normalized tokens.
    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static let saltKey = "knowledge.fingerprintSalt"

    /// Per-install random salt. Not a user secret — it only prevents offline
    /// dictionary reconstruction of rejected facts — so UserDefaults is fine.
    private static var salt: String {
        if let existing = UserDefaults.standard.string(forKey: saltKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: saltKey)
        return fresh
    }
}

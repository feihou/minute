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

    /// The same normalization with the tokens left in the order they were
    /// written. `normalized` sorts, which is what dedup wants and what a
    /// phrase match cannot use: after sorting, the two words of a name are
    /// adjacent only by accident of the alphabet.
    static func inOrder(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    /// Order-preserving equality of two statements.
    ///
    /// `normalized` sorts tokens so dedup can catch a reordering, which also
    /// makes "assigned Alex to Jordan" and "assigned Jordan to Alex" identical
    /// to it. Dropping the second as a duplicate is one thing; recording it as
    /// corroboration is another, because that claims both meetings said the
    /// same thing — and a promotion would later put the first meeting's words
    /// under the second meeting's name.
    static func statesTheSame(_ a: String, _ b: String) -> Bool {
        tokens(a) == tokens(b)
    }

    /// Jaccard similarity of normalized tokens, 0...1. Unspaced scripts
    /// (CJK) yield one giant token, so when either side has fewer than
    /// `wordTokenFloor` word tokens the comparison falls back to character
    /// bigrams — deterministic and script-agnostic, keeping the fuzzy band
    /// useful for languages without inter-word spaces.
    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let ta = tokens(a)
        let tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if min(ta.count, tb.count) < wordTokenFloor {
            return jaccard(Set(bigrams(ta.joined(separator: " "))), Set(bigrams(tb.joined(separator: " "))))
        }
        return jaccard(Set(ta), Set(tb))
    }

    private static let wordTokenFloor = 3

    private static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count > 1 else { return [text] }
        return zip(chars, chars.dropFirst()).map { String([$0, $1]) }
    }

    private static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Whether `quote` appears in `transcript`, ignoring case, diacritics,
    /// punctuation, and whitespace runs — the sourceQuote validation gate.
    ///
    /// Both sides are padded with spaces so a match can only start and end on
    /// a token boundary: a quote that only matches by cutting into a word
    /// ("own the atlas plan" inside "I disown the atlas plan") would let the
    /// model ground a fact in text the transcript does not say.
    ///
    /// Unspaced scripts have no such boundary to land on. `tokens` splits on
    /// non-alphanumerics and ideographs are alphanumerics, so a whole Chinese
    /// clause is a single token, and the padded form would validate a quote
    /// only when it spans complete punctuation-delimited clauses — routing
    /// every ordinary fragment to `.suggested` with no sourceQuote. So a
    /// second pass accepts an unpadded occurrence whose neighbouring
    /// characters are not ASCII alphanumerics: that is still a word boundary
    /// wherever words are spelled out, so "own the atlas plan" stays refused
    /// inside "disown", while a verbatim CJK fragment validates.
    static func contains(transcript: String, quote: String) -> Bool {
        let q = tokens(quote).joined(separator: " ")
        guard !q.isEmpty else { return false }
        let haystack = tokens(transcript).joined(separator: " ")
        if (" " + haystack + " ").contains(" " + q + " ") { return true }
        // Every occurrence, not just the first: the one that cuts into a word
        // can precede the one that does not.
        var searchFrom = haystack.startIndex
        while let found = haystack.range(of: q, range: searchFrom..<haystack.endIndex) {
            let before = found.lowerBound == haystack.startIndex
                ? nil
                : haystack[haystack.index(before: found.lowerBound)]
            let after = found.upperBound == haystack.endIndex ? nil : haystack[found.upperBound]
            if !isASCIIAlphanumeric(before), !isASCIIAlphanumeric(after) { return true }
            searchFrom = haystack.index(after: found.lowerBound)
        }
        return false
    }

    private static func isASCIIAlphanumeric(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isASCII && (character.isLetter || character.isNumber)
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

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
    /// characters are not word-internal.
    ///
    /// Segmentation, not case, is what separates the two families. A script
    /// that puts spaces between its words has a boundary to land on whether or
    /// not it has letter case — Latin, Cyrillic and Greek do, and so do Arabic,
    /// Hebrew and Devanagari — so cutting into one of their words is the abuse
    /// the gate exists to refuse. Only the scripts written without inter-word
    /// spaces (Han, kana, Hangul, Thai, Lao, Khmer, Myanmar, Tibetan) have
    /// nothing for a fragment to align to. So "own the atlas plan" stays
    /// refused inside "disown", "обственник" inside "собственник" and
    /// "درسة" inside "المدرسة", while a verbatim CJK fragment validates.
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
            if !isWordInternal(before), !isWordInternal(after) { return true }
            searchFrom = haystack.index(after: found.lowerBound)
        }
        return false
    }

    /// Whether a neighbouring character means the occurrence cut into a word.
    /// Any letter or number does — including the letters diacritic folding
    /// leaves alone (ø, æ, ł, đ), and digits so "plan" can't be carved out of
    /// "plan2" — unless it belongs to a script that writes without spaces, the
    /// one family where a fragment has no boundary to land on.
    private static func isWordInternal(_ character: Character?) -> Bool {
        guard let character, character.isLetter || character.isNumber else { return false }
        guard let scalar = character.unicodeScalars.first else { return false }
        return !isUnsegmentedScript(scalar)
    }

    /// Whether a scalar is written in a script that does not separate words
    /// with spaces. Block ranges rather than `Unicode.Script`, which Foundation
    /// does not expose: the boundary this draws is coarse by design — one
    /// scalar of a neighbouring word is all the second pass ever inspects, and
    /// a block is admitted whenever the script writes any of its letters inside
    /// a word.
    private static func isUnsegmentedScript(_ scalar: Unicode.Scalar) -> Bool {
        unsegmentedScriptBlocks.contains { $0.contains(scalar.value) }
    }

    private static let unsegmentedScriptBlocks: [ClosedRange<UInt32>] = [
        0x0E00...0x0E7F,  // Thai
        0x0E80...0x0EFF,  // Lao
        0x0F00...0x0FFF,  // Tibetan
        0x1000...0x109F,  // Myanmar
        0x1100...0x11FF,  // Hangul Jamo
        0x1780...0x17FF,  // Khmer
        // Unicode files the iteration marks 々 (U+3005) and 〆 (U+3006) under
        // punctuation, but Japanese writes them inside words and `isLetter`
        // agrees, so they belong to the unspaced family like the kana beside
        // them — otherwise a verbatim quote next to one reads as a cut word.
        0x3000...0x303F,  // CJK Symbols and Punctuation
        0x3040...0x309F,  // Hiragana
        0x30A0...0x30FF,  // Katakana
        0x3100...0x312F,  // Bopomofo
        0x3130...0x318F,  // Hangul Compatibility Jamo
        0x31F0...0x31FF,  // Katakana Phonetic Extensions
        0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
        0x4E00...0x9FFF,  // CJK Unified Ideographs
        0xAC00...0xD7AF,  // Hangul Syllables
        0xF900...0xFAFF,  // CJK Compatibility Ideographs
        0xFF66...0xFF9F,  // Halfwidth CJK forms (halfwidth katakana, Hangul)
        0x20000...0x2FA1F,  // CJK Unified Ideographs Extensions B+ and compatibility supplement
    ]

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

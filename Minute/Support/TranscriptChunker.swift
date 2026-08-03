import Foundation

/// Splits a transcript into pieces small enough for the on-device model's
/// 4,096-token context window (instructions + prompt + output share it).
enum TranscriptChunker {
    /// ~6,000 chars ≈ 1,500 tokens, leaving headroom for instructions and output.
    static let defaultMaxChars = 6_000

    /// Trailing lines of each chunk are repeated at the start of the next, so
    /// a discussion that spans a boundary is seen whole at least once.
    static let defaultOverlapChars = 600

    static func chunks(
        from text: String,
        maxChars: Int = defaultMaxChars,
        overlapChars: Int = defaultOverlapChars
    ) -> [String] {
        precondition(maxChars > 0, "maxChars must be positive")
        // Cap the overlap so every chunk still makes real forward progress.
        let overlap = min(max(overlapChars, 0), maxChars / 2)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxChars else { return [trimmed] }

        // Split on line boundaries (one transcript segment per line); hard-split
        // any pathological single line that exceeds the budget on its own.
        var pieces: [String] = []
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = String(line)
            while rest.count > maxChars {
                let cut = rest.index(rest.startIndex, offsetBy: maxChars)
                pieces.append(String(rest[..<cut]))
                rest = String(rest[cut...])
            }
            if !rest.isEmpty {
                pieces.append(rest)
            }
        }

        var chunks: [String] = []
        var current: [String] = []
        var currentCount = 0

        for piece in pieces {
            let addition = current.isEmpty ? piece.count : piece.count + 1
            if !current.isEmpty, currentCount + addition > maxChars {
                chunks.append(current.joined(separator: "\n"))

                // Seed the next chunk with the tail of this one (the overlap).
                var tail: [String] = []
                var tailCount = 0
                for line in current.reversed() {
                    let lineAddition = tail.isEmpty ? line.count : line.count + 1
                    guard tailCount + lineAddition <= overlap else { break }
                    tail.insert(line, at: 0)
                    tailCount += lineAddition
                }
                // A single trailing line longer than the whole overlap budget
                // would otherwise kill the overlap exactly where one speaker
                // talks for a long stretch — carry its suffix instead,
                // trimmed to the first word boundary.
                if tail.isEmpty, overlap > 0, let last = current.last, last.count > overlap {
                    var suffix = String(last.suffix(overlap))
                    if let space = suffix.firstIndex(of: " "), suffix.index(after: space) < suffix.endIndex {
                        suffix = String(suffix[suffix.index(after: space)...])
                    }
                    if !suffix.isEmpty {
                        tail = [suffix]
                        tailCount = suffix.count
                    }
                }
                current = tail
                currentCount = tailCount

                // The overlap must never push a chunk over budget; shed the
                // oldest carried lines until the incoming piece fits.
                while !current.isEmpty, currentCount + piece.count + 1 > maxChars {
                    let removed = current.removeFirst()
                    currentCount -= current.isEmpty ? removed.count : removed.count + 1
                }
            }
            currentCount += current.isEmpty ? piece.count : piece.count + 1
            current.append(piece)
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }
}

import Foundation

/// Splits a transcript into pieces small enough for the on-device model's
/// 4,096-token context window (instructions + prompt + output share it).
enum TranscriptChunker {
    /// ~6,000 chars ≈ 1,500 tokens, leaving headroom for instructions and output.
    static let defaultMaxChars = 6_000

    static func chunks(from text: String, maxChars: Int = defaultMaxChars) -> [String] {
        precondition(maxChars > 0, "maxChars must be positive")
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
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= maxChars {
                current += "\n" + piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

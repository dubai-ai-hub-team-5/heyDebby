import Foundation

/// Watches streamed agent output for the confirm marker.
///
/// Line-buffered because a pipe splits wherever it likes — including through the middle
/// of the word `NEED`. Only the first marker is reported: the agent is told to print one
/// and stop, and a second would mean the gate is already open.
struct NeedScanner {
    private var line = ""
    private var fired = false

    /// Returns the question after `NEED:` once its line is complete.
    mutating func feed(_ chunk: String) -> String? {
        var hit: String?
        for ch in chunk {
            // `isNewline`, not `== "\n"`: a PTY-wrapped subprocess writes "\r\n", and Swift
            // fuses that into a single grapheme cluster distinct from plain "\n" whenever
            // both bytes land in the same chunk — `== "\n"` never matches it and the line
            // is never terminated. `isNewline` also catches a lone "\r" when the chunk
            // boundary falls between the \r and the \n.
            if ch.isNewline {
                if let n = take(line) { hit = hit ?? n }
                line = ""
            } else {
                line.append(ch)
            }
        }
        return hit
    }

    /// The agent usually exits without a trailing newline; call this on termination.
    mutating func flush() -> String? {
        let n = take(line)
        line = ""
        return n
    }

    private mutating func take(_ l: String) -> String? {
        guard !fired else { return nil }
        let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.uppercased().hasPrefix("NEED:") else { return nil }
        let q = String(t.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        fired = true
        return q
    }
}

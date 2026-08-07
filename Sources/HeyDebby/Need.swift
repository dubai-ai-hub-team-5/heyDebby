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
            if ch == "\n" {
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
        let t = l.trimmingCharacters(in: .whitespaces)
        guard t.uppercased().hasPrefix("NEED:") else { return nil }
        let q = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        fired = true
        return q
    }
}

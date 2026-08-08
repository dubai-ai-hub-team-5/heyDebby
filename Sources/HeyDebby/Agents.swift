import Foundation

/// Assembles pipe chunks into whole lines and keeps only the last `cap` of them.
///
/// The notch was a one-line ticker, so it could take "the last non-empty line in this
/// chunk" and ignore the rest. A card that shows a scrolling tail cannot: a pipe splits
/// wherever it likes, so a line routinely arrives across two chunks and the tail has to
/// join them back together — the same reason `NeedScanner` is line-buffered, and the
/// same `isNewline` (not `== "\n"`) so a "\r\n" fused into one grapheme still terminates
/// a line.
///
/// Bounded on purpose: an agent that runs for an hour can print megabytes, and none of it
/// past the last few lines is ever on screen.
struct OutputTail {
    static let defaultCap = 60

    private(set) var lines: [String] = []
    private var partial = ""
    let cap: Int

    init(cap: Int = OutputTail.defaultCap) { self.cap = cap }

    mutating func feed(_ chunk: String) {
        for ch in chunk {
            if ch.isNewline {
                push(partial)
                partial = ""
            } else {
                partial.append(ch)
            }
        }
    }

    /// The last line of a run usually has no trailing newline; call this at exit or it is
    /// never shown — and that final line is the one carrying the result.
    mutating func flush() { push(partial); partial = "" }

    /// The newest line, for the collapsed pill. Empty only before anything has printed.
    var newest: String { lines.last ?? "" }

    private mutating func push(_ l: String) {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        lines.append(t)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }
}

/// One background agent, start to finish. Every run owns its own status, output and
/// process, which is the whole point: the previous single `agentBusy` / `agentLine` /
/// `gate` triple meant a second agent silently overwrote the first one's UI, and two runs
/// that both paused on a NEED: question shared one slot — the second question replaced
/// the first, and Confirm then resumed whichever session happened to be in the box.
@MainActor
final class AgentRun: ObservableObject, Identifiable {
    /// `asking` carries the NEED: question. It is deliberately part of the status rather
    /// than a separate flag: a run cannot be both running and waiting, and making that
    /// unrepresentable is what stops the gate drifting out of sync with the run again.
    enum Status: Equatable {
        case running
        case asking(String)
        case done
        case failed(Int32)
        case stopped
    }

    let id = UUID()
    let task: String
    /// The CLI session, fixed for the life of the run so Confirm always resumes the
    /// session that actually asked — it cannot be crossed with another run's.
    let session: String
    let startedAt = Date()

    @Published var status: Status = .running
    /// Republished from `tail` so SwiftUI sees the change; `tail` is a value type.
    @Published private(set) var lines: [String] = []

    /// Replaced on Confirm, when a fresh `claude -r` process reattaches to the session.
    var process: Process?
    private var tail = OutputTail()
    private var scanner = NeedScanner()

    init(task: String, session: String) {
        self.task = task
        self.session = session
    }

    var isFinished: Bool {
        switch status {
        case .running, .asking: return false
        case .done, .failed, .stopped: return true
        }
    }

    /// What the collapsed pill shows.
    ///
    /// The task, not the newest output line. Four agents ticking away four different
    /// progress lines are four pills you cannot tell apart — which one is the receipts
    /// job? — and identity is what a glance down the rail is actually asking. The output
    /// is one hover away, which is the whole arrangement: pill says *which*, card says
    /// *what is happening*.
    ///
    /// A pending question is the exception, because it is not progress: it is a request
    /// aimed at the user, and burying it behind a hover would leave the run stalled until
    /// somebody happened to look.
    var summary: String {
        if case .asking(let q) = status { return q }
        return task
    }

    /// Feeds a chunk of streamed output. Returns the NEED: question if this chunk
    /// completed one, so the caller can speak it — the status is already updated.
    @discardableResult
    func absorb(_ chunk: String) -> String? {
        tail.feed(chunk)
        lines = tail.lines
        guard let q = scanner.feed(chunk) else { return nil }
        status = .asking(q)
        return q
    }

    /// Called once the process exits. Returns a late NEED: found in an unterminated final
    /// line, for the same reason `absorb` does.
    @discardableResult
    func finish(exitCode: Int32) -> String? {
        tail.flush()
        lines = tail.lines
        process = nil
        let late = scanner.flush()
        if let late { status = .asking(late) }
        // A run that already asked stays asking: it exited *because* it was told to stop
        // and wait, so exit code 0 here means "paused successfully", not "job done".
        if case .asking = status { return late }
        status = exitCode == 0 ? .done : .failed(exitCode)
        return late
    }
}

/// How long a finished run stays on the rail before it removes itself.
///
/// Only `done` expires. A failure keeps its card until dismissed — the exit code and the
/// last few lines are the entire diagnosis, and a card that deletes itself twelve seconds
/// after an agent fails is a card that guarantees nobody reads it. `asking` never expires
/// for the obvious reason. `stopped` was the user's own doing, so it goes with `done`.
func railTTL(for status: AgentRun.Status) -> TimeInterval? {
    switch status {
    case .done, .stopped: return 12
    case .failed, .running, .asking: return nil
    }
}

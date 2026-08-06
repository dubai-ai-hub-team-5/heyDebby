import Foundation

/// Runs AppleScript for the `RUN:` marker.
///
/// This exists instead of reusing `AgentRunner.spawn` because that path goes through
/// `zsh -lc`, where one quoting bug turns a model-written line into arbitrary shell.
/// Here the statement is an argument to `/usr/bin/osascript` and can only ever be
/// AppleScript.
enum Control {
    /// The argv osascript gets: one `-e` per statement, in order.
    static func arguments(for statements: [String]) -> [String] {
        statements.flatMap { ["-e", $0] }
    }

    /// Runs the statements and reports the exit code plus whatever osascript printed.
    /// Output is stderr-and-stdout combined: AppleScript errors arrive on stderr and are
    /// the entire diagnosis when an app is not running or Automation was denied.
    ///
    /// `onDone` always lands on the main queue — every exit path hops there, since the
    /// caller is `@MainActor` UI code.
    static func run(_ statements: [String], onDone: @escaping (Int32, String) -> Void) {
        guard !statements.isEmpty else {
            return DispatchQueue.main.async { onDone(0, "") }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = arguments(for: statements)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        DebbyLog.write("RUN osascript \(statements.joined(separator: " ; "))")
        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            DebbyLog.write("RUN exit \(p.terminationStatus) \(text.prefix(200))")
            DispatchQueue.main.async { onDone(p.terminationStatus, text) }
        }
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { onDone(-1, error.localizedDescription) }
        }
    }
}

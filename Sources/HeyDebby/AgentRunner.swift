import Foundation

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Pure command builder (selfcheck-tested). backend: "codex" or "claude".
func agentCommand(backend: String, task: String, screenshotPath: String?, fullAccess: Bool) -> String {
    if backend == "codex" {
        var cmd = "codex exec --skip-git-repo-check"
        if let p = screenshotPath { cmd += " -i \(shellQuote(p))" }
        cmd += fullAccess ? " --dangerously-bypass-approvals-and-sandbox" : " -s read-only"
        return cmd + " \(shellQuote(task))"
    }
    var prompt = task
    if let p = screenshotPath {
        prompt += "\n\n(Context: a screenshot of my screen from when I asked this is at \(p) — read it if visual context helps.)"
    }
    if fullAccess {
        return "claude -p --dangerously-skip-permissions \(shellQuote(prompt))"
    }
    // Without an allowlist `claude -p` denies every tool, so an app task fails silently.
    // --allowedTools is variadic: it must be last, and the prompt must precede it.
    // Bash(osascript:*) is scoped rather than bare Bash deliberately: an agent that can
    // run AppleScript is a much smaller grant than one that can run anything.
    return "claude -p \(shellQuote(prompt)) --allowedTools mcp__composio Read Glob Grep Bash(osascript:*)"
}

// Both CLIs have the Composio MCP gateway registered (connect.composio.dev) —
// this note tells the agent to use it and to surface app-connection links to the user.
let composioNote = """

(You have Composio MCP tools for the user's apps — Gmail, Calendar, Notion, Slack, GitHub and more. \
For app tasks: COMPOSIO_SEARCH_TOOLS to find tools, COMPOSIO_MULTI_EXECUTE_TOOL to run them. \
If an app isn't connected yet, use COMPOSIO_MANAGE_CONNECTIONS and print the connection URL clearly \
so the user can authorize it in their browser.)
"""

/// The login shell an app-launched CLI gets: `-l` sources .zprofile but NOT .zshrc,
/// so anything a user set up interactively (nvm etc.) is absent — hence the explicit PATH.
let cliPathPrefix = "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:$PATH\"; "

/// One-shot: run a command and get everything it printed once it exits.
func shellOutput(_ cmd: String) async throws -> String {
    let buf = OutputBox()
    return try await withCheckedThrowingContinuation { cont in
        AgentRunner.spawn(cliPathPrefix + cmd,
                          onOutput: { buf.append($0) },
                          onDone: { code in
            let text = buf.text
            if code == 0 { cont.resume(returning: text) }
            else { cont.resume(throwing: NSError(domain: "cli", code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: text.isEmpty ? "CLI exited \(code)" : String(text.suffix(400))])) }
        })
    }
}

/// onOutput lands on the pipe's queue and onDone on the termination queue — different
/// threads, so the buffer needs a lock rather than a bare captured var.
/// Internal (not private): Control.swift reuses this for the same reason.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = ""
    func append(_ s: String) { lock.lock(); buf += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buf }
}

// Background agents = Codex CLI (ChatGPT subscription) or Claude Code CLI.
enum AgentRunner {
    /// Returns the running process so callers can terminate it (nil if launch failed).
    /// `exec` replaces the shell with the CLI, so terminate() reaches the agent itself.
    @discardableResult
    static func run(backend: String, task: String, screenshotPath: String?, fullAccess: Bool,
                    onOutput: @escaping (String) -> Void, onDone: @escaping (Int32) -> Void) -> Process? {
        let agent = agentCommand(backend: backend, task: task + composioNote,
                                 screenshotPath: screenshotPath, fullAccess: fullAccess)
        DebbyLog.write("AGENT (\(backend)) \(task)")
        return spawn(cliPathPrefix + "exec \(agent)", onOutput: onOutput, onDone: onDone)
    }

    @discardableResult
    static func spawn(_ command: String, onOutput: @escaping (String) -> Void,
                      onDone: @escaping (Int32) -> Void) -> Process? {
        let cmd = command + " 2>&1"
        DebbyLog.write("RUN \(command)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", cmd]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // `codex exec` reads stdin ("Reading additional input from stdin…") and blocks
        // forever if it never sees EOF. We inherit the GUI app's stdin otherwise, which
        // is not something to gamble a silent hang on.
        proc.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                DebbyLog.raw(s)   // stream it: a run that hangs still leaves a trail
                onOutput(s)
            }
        }
        proc.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DebbyLog.write("EXIT \(p.terminationStatus)")
            onDone(p.terminationStatus)
        }
        do {
            try proc.run()
        } catch {
            onOutput("Failed to launch the agent CLI: \(error.localizedDescription)\nIs it installed? (codex: `brew install codex` + `codex login`; claude: https://claude.com/claude-code)")
            onDone(-1)
            return nil
        }
        return proc
    }
}

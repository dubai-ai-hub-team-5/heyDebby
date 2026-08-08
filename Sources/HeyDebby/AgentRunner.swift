import Foundation

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Pure command builder (selfcheck-tested). backend: "codex" or "claude".
func agentCommand(backend: String, task: String, screenshotPath: String?,
                  fullAccess: Bool, appControl: Bool = false,
                  session: String? = nil, resume: Bool = false,
                  browser: Bool = false, settingsPath: String? = nil) -> String {
    if backend == "codex" {
        // `codex exec` has no session-resume equivalent, so session/resume are ignored here.
        var cmd = "codex exec --skip-git-repo-check"
        if let p = screenshotPath { cmd += " -i \(shellQuote(p))" }
        cmd += fullAccess ? " --dangerously-bypass-approvals-and-sandbox" : " -s read-only"
        return cmd + " \(shellQuote(task))"
    }
    var prompt = task
    if let p = screenshotPath {
        prompt += "\n\n(Context: a screenshot of my screen from when I asked this is at \(p) — read it if visual context helps.)"
    }
    // `-r <id>` reattaches to the paused run; `--session-id <id>` names a fresh one so we
    // can reattach later without parsing a session id back out of the CLI's output (which
    // would force --output-format json and break the streaming ticker the notch relies on).
    var sessionFlag = ""
    if let s = session { sessionFlag = resume ? " -r \(shellQuote(s))" : " --session-id \(shellQuote(s))" }
    if fullAccess && !browser {
        return "claude -p\(sessionFlag) --dangerously-skip-permissions \(shellQuote(prompt))"
    }
    // Without an allowlist `claude -p` denies every tool, so an app task fails silently.
    // --allowedTools is variadic: it must be last, and the prompt must precede it.
    var tools = "mcp__composio Read Glob Grep"
    if browser { tools += " mcp__playwright" }
    let settingsFlag = settingsPath.map { " --settings \(shellQuote($0))" } ?? ""
    return "claude -p\(sessionFlag)\(settingsFlag) \(shellQuote(prompt)) --allowedTools \(tools)"
}

let playwrightMCPVersion = "0.0.79"

func browserSetupCommand(userDataDir: String) -> String {
    "claude mcp add playwright --scope user -- npx -y @playwright/mcp@\(playwrightMCPVersion) "
        + "--user-data-dir \(shellQuote(userDataDir))"
}

// Both CLIs have the Composio MCP gateway registered (connect.composio.dev) —
// this note tells the agent to use it and to surface app-connection links to the user.
let composioNote = """

(You have Composio MCP tools for the user's apps — Gmail, Calendar, Notion, Slack, GitHub and more. \
For app tasks: COMPOSIO_SEARCH_TOOLS to find tools, COMPOSIO_MULTI_EXECUTE_TOOL to run them. \
If an app isn't connected yet, use COMPOSIO_MANAGE_CONNECTIONS and print the connection URL clearly \
so the user can authorize it in their browser.)
"""

/// Appended to every agent task while browser control is on. No per-task classification:
/// a note costs less than code that guesses which tasks are form tasks.
///
/// The profile PATH is passed, never its contents — a passport number on a command line
/// is visible to every process on the machine via `ps`.
///
/// This is the ONLY thing standing between the agent and clicking Submit on a real form —
/// mcp__playwright sits in `agentCommand`'s allowlist unconditionally (see its comment),
/// so once the Playwright server is registered, whether Debby actually READS this note is
/// the entire safety boundary. That is also why `AppState.disableBrowserControl()`
/// unregisters the server when the toggle goes off: without that, turning browser control
/// "off" would silently stop attaching this note to future tasks while leaving the browser
/// tool itself fully callable — the one guardrail gone, the capability still live.
let browserNote = """

(You can drive a real browser with the Playwright tools. The user's own details — name, \
date of birth, ID numbers, address — are in \(Profile.url.path); read that file when a \
form asks for them, and say so if it is missing or lacks the field you need.

Leave the browser window open so the user can watch and take over.

NEVER type a password, a card number, or a one-time code. NEVER attempt a CAPTCHA. NEVER \
click Submit, Pay, Confirm, or anything else that cannot be undone.

When you reach any of those, or the form's own review page, print exactly one line:
NEED: <one sentence saying what you need or what is about to happen>
then stop and do nothing further. The user answers, and you will be resumed.)
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

enum ProcessLogging {
    case standard
    case privateOutput(label: String)
}

// Background agents = Codex CLI (ChatGPT subscription) or Claude Code CLI.
enum AgentRunner {
    /// Returns the running process so callers can terminate it (nil if launch failed).
    /// `exec` replaces the shell with the CLI, so terminate() reaches the agent itself.
    @discardableResult
    static func run(backend: String, task: String, screenshotPath: String?, fullAccess: Bool, appControl: Bool,
                    session: String? = nil, resume: Bool = false, browser: Bool = false,
                    onOutput: @escaping (String) -> Void, onDone: @escaping (Int32) -> Void) -> Process? {
        let effectiveBrowser = browser && backend == "claude"
        var settingsURL: URL?
        if effectiveBrowser {
            do {
                let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
                let data = try BrowserPolicy.settingsJSON(executablePath: executable)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("heydebby-browser-policy-\(UUID().uuidString).json")
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: url.path)
                settingsURL = url
            } catch {
                onOutput("Failed to create the browser safety policy: \(error.localizedDescription)")
                onDone(-1)
                return nil
            }
        }
        let agent = agentCommand(backend: backend,
                                 task: task + composioNote + (effectiveBrowser ? browserNote : ""),
                                 screenshotPath: screenshotPath, fullAccess: fullAccess, appControl: appControl,
                                 session: session, resume: resume, browser: effectiveBrowser,
                                 settingsPath: settingsURL?.path)
        DebbyLog.write("AGENT (\(backend)) \(task)")
        return spawn(cliPathPrefix + "exec \(agent)", onOutput: onOutput, onDone: { code in
            if let settingsURL { try? FileManager.default.removeItem(at: settingsURL) }
            onDone(code)
        })
    }

    @discardableResult
    static func spawn(_ command: String, logging: ProcessLogging = .standard,
                      logSink: LogSink? = nil, onOutput: @escaping (String) -> Void,
                      onDone: @escaping (Int32) -> Void) -> Process? {
        let cmd = command + " 2>&1"
        func logWrite(_ text: String) {
            if let logSink { logSink.write(text) } else { DebbyLog.write(text) }
        }
        func logRaw(_ text: String) {
            if let logSink { logSink.raw(text) } else { DebbyLog.raw(text) }
        }
        let privateLabel: String?
        switch logging {
        case .standard:
            privateLabel = nil
            logWrite("RUN \(command)")
        case .privateOutput(let label):
            privateLabel = label
            logWrite("RUN \(label)")
        }
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
        // terminationHandler and the pipe's readabilityHandler are independent dispatch
        // sources with no ordering guarantee between them: termination can fire while the
        // last chunk written by the child is still sitting unread in the pipe. Tearing the
        // handler down from terminationHandler (as this used to) drops that chunk on the
        // floor — verified empirically, ~1 in 300 runs of a process that writes then exits
        // immediately. That's exactly where an agent's NEED: marker lives, since it prints
        // the line and exits right after — losing it means the gate silently never opens.
        // Fix: let the read side detect its own EOF (an empty read) and wait for both EOF
        // and process-exit before reporting done, per Apple's documented pattern for
        // FileHandle.readabilityHandler.
        let group = DispatchGroup()
        var exitCode: Int32 = 0
        group.enter()   // left once the pipe hits EOF
        group.enter()   // left once the process has exited
        // Waiting for both sides unconditionally trades one bug for another: a descendant
        // that outlives `proc` and still holds the pipe's write end open (an orphaned MCP
        // stdio server, a backgrounded tool) means EOF may never arrive even though `proc`
        // itself has long since exited — group.notify would then wait forever, and since
        // this is the one path every backend shares, shellOutput's caller (the plain chat
        // backend) would hang instead of erroring. finishOnce below makes "EOF actually
        // arrives" and "the grace period expires" a race with a single winner: whichever
        // happens first reports done, and the loser is a no-op.
        let doneLock = NSLock()
        var finished = false
        func finishOnce() {
            doneLock.lock()
            let already = finished
            finished = true
            doneLock.unlock()
            guard !already else { return }
            onDone(exitCode)
        }
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else {
                h.readabilityHandler = nil
                group.leave()
                return
            }
            if let s = String(data: d, encoding: .utf8) {
                if privateLabel == nil { logRaw(s) }
                onOutput(s)
            }
        }
        proc.terminationHandler = { p in
            exitCode = p.terminationStatus
            if let privateLabel { logWrite("EXIT \(privateLabel) \(p.terminationStatus)") }
            else { logWrite("EXIT \(p.terminationStatus)") }
            group.leave()
            // A few seconds is plenty for a pipe that's actually drained (EOF normally
            // arrives within milliseconds of exit); past that, a descendant is still
            // holding it open and more output isn't coming on any schedule we control.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                doneLock.lock()
                let stillWaiting = !finished
                doneLock.unlock()
                if stillWaiting {
                    logWrite("EOF grace period expired — proceeding with partial output")
                    pipe.fileHandleForReading.readabilityHandler = nil
                }
                finishOnce()
            }
        }
        group.notify(queue: .global(), execute: finishOnce)
        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            onOutput("Failed to launch the agent CLI: \(error.localizedDescription)\nIs it installed? (codex: `brew install codex` + `codex login`; claude: https://claude.com/claude-code)")
            onDone(-1)
            return nil
        }
        return proc
    }
}

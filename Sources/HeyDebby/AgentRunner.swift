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
    // The allowlist below only means "read-only" if nothing else widens it, and something
    // else routinely does: `--allowedTools` adds to the user's own ~/.claude/settings.json
    // rather than replacing it, so a `permissions.defaultMode` of `auto` (or acceptEdits,
    // or bypassPermissions) there silently grants every agent Write and Bash. Verified on
    // a machine with `auto` set: an agent told to write a file wrote it, allowlist and all.
    // Debby's own posture must not depend on how the user configured a different tool, in
    // either direction — so it is pinned here. `manual` is the ask-for-everything mode,
    // which in `-p` (nobody to ask) means deny, while allowlisted tools still run.
    let pin = " --permission-mode manual"
    // Without an allowlist `claude -p` denies every tool, so an app task fails silently.
    // --allowedTools is variadic: it must be last, and the prompt must precede it.
    var tools = "mcp__composio Read Glob Grep"
    if browser { tools += " mcp__playwright" }
    let settingsFlag = settingsPath.map { " --settings \(shellQuote($0))" } ?? ""
    return "claude -p\(sessionFlag)\(pin)\(settingsFlag) \(shellQuote(prompt)) --allowedTools \(tools)"
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

/// Guidance appended while browser control is on. The executable boundary is
/// `BrowserPolicy`; this text explains how the agent should respond to a denial.
/// The profile path is included only after its stored structure validates, and profile
/// contents never appear on the command line.
func browserGuidance(profileURL: URL?) -> String {
    let profile: String
    if let profileURL {
        profile = "The user's validated details are in \(profileURL.path); read that file when an ordinary form field asks for them."
    } else {
        profile = "No validated profile is available. Do not invent missing personal details."
    }
    return """
    (You can drive a real browser with the Playwright tools. \(profile)

    Leave the browser open so the user can watch and take over. Never type a password, card \
    number, one-time code, or CAPTCHA response. The browser policy enforces the final boundary.

    If a browser operation is denied, stop immediately and leave the browser open for the user \
    to complete that action directly. Do not ask to resume or retry the denied operation.)
    """
}

/// Appended while full access is on — the only mode in which an agent can finish a job
/// rather than just describe one, since every other mode denies Write and Bash.
///
/// The capability being described is command execution, so the note describes exactly
/// that and nothing narrower. An earlier draft explained how to build a spreadsheet, and
/// a note that explains one task is a note that teaches the agent which task it is for:
/// the formats named below are examples of a general power, not a menu of what Debby
/// supports. Anything a command can do is in scope.
///
/// What it does pin down is the handful of choices every run would otherwise re-decide,
/// each of which has one clearly better answer:
///
/// - Where output goes, so ten runs don't invent ten locations.
/// - How to get a tool that isn't installed. `uv run --with` / `uvx` fetch per-run and
///   leave nothing behind, which beats an agent running `brew install` on someone's Mac.
/// - Files, never AppleScript, for producing a document: writing an .xlsx needs no
///   Automation grant, works with Excel closed, and cannot clobber unsaved edits in a
///   workbook the user has open. Driving apps is the interactive `RUN:` rail's job.
/// - Verify before reporting, because an agent that cannot see the notch has no other way
///   to notice it produced nothing.
///
/// The workspace is a convention and this note is the whole of its enforcement — see
/// `Workspace`. Nothing here restrains a full-access agent, and nothing here is pretending
/// to; the setting's own warning is the boundary.
let workNote = """

(You can run any command on this Mac and create or change any file of any kind. Treat the \
request as a job to finish end to end — there is no fixed list of things you support, so \
work out what it needs, run it, and check the result. Writing a Python script and running \
it is usually the shortest route; keep the script beside its output so the user can re-run \
or adjust it. Put whatever you make in \(Workspace.path) unless the user asked for \
somewhere specific — the folder already exists.

Nothing needs to be preinstalled: `uvx <tool>` runs a command-line tool and \
`uv run --with <package> python script.py` runs a script against any Python library, \
neither installing anything permanently — openpyxl for Excel, python-pptx for PowerPoint, \
python-docx for Word, pypdf or reportlab for PDFs, pandas for data, pillow for images, and \
whatever else the job actually needs. If uv is missing, fall back to \
`python3 -m pip install --user <package>` or to what the Mac already has (sips, textutil, \
sqlite3, qlmanage).

Produce the real format rather than something that resembles it — a genuine .xlsx with \
working formulas, a real .pptx, not a renamed .csv or a text file with the wrong \
extension. Do NOT remote-control a GUI app (Excel, PowerPoint, Word, Numbers, Keynote, \
Pages) through AppleScript to build a file: it needs an Automation grant this run does not \
have, it fails when the app is closed, and it can destroy unsaved work.

Before reporting the job done, verify it — open the file back up in the same library, \
re-run the command, check the output really is what was asked for — and say plainly if it \
isn't. Then run `open` on what you made so the user sees it, and print its full path on \
its own line.)
"""

/// Appended when full access is off, which is the default. The grant is Read/Glob/Grep
/// plus the MCP gateways, so an agent asked to make a spreadsheet cannot make one — and
/// `claude -p` discovers that mid-run, several minutes in, with no way to ask.
///
/// Without this note the notch shows the ticker scrolling and then "✅ agent done" over a
/// job that never happened, which is the worst of the three possible outcomes. With it the
/// agent names the switch to flip. That is the whole fix: the capability is not widened
/// here, only the silence.
///
/// Worded around *changing things* rather than around denied tools, because the two
/// backends deny different ones: claude has no Bash at all here, while `codex exec
/// -s read-only` will happily run a command that only reads. Both are "can look, cannot
/// touch", and that is the only claim this makes.
let readOnlyNote = """

(You can read files and use the user's connected apps, but you cannot change anything on \
this Mac — writing or deleting a file, installing anything, changing a setting — and this \
run is unattended, so nothing can be approved mid-way. If the task needs any of that, do \
whatever part you can, then say in one line that the rest needs "Agents: full access" \
switched on in Debby's settings. Never claim to have done something you were not able to do.)
"""

/// Browser-enabled runs stay on a scoped allowlist even when the global full-access
/// setting is on. This keeps the executable browser policy in force and avoids telling
/// the agent either that it has a shell or that the user should toggle a setting that is
/// already enabled.
let browserModeNote = """

(This run can read files, use connected apps, and drive the browser through the Playwright \
tools, but it cannot run arbitrary commands or change local files. Complete the browser task \
within those capabilities and never claim to have performed a local change you could not make.)
"""

/// Appended to every agent task while browser control is on. No per-task classification:
/// a note costs less than code that guesses which tasks are form tasks.
///
/// The profile PATH is passed, never its contents — a passport number on a command line
/// is visible to every process on the machine via `ps`.
///
/// Playwright is granted only for browser-enabled runs, and BrowserPolicy remains the
/// executable safety boundary. This note tells the agent how to hand control back when
/// that policy refuses a sensitive or final action.
func agentPrompt(task: String, fullAccess: Bool, browser: Bool,
                 profileURL: URL? = nil) -> String {
    // Browser runs deliberately never use the full-access CLI branch: doing so would
    // bypass the per-tool policy. Keep the capability note honest about that narrower
    // execution mode even when the global full-access toggle is on.
    let capability = browser ? browserModeNote : (fullAccess ? workNote : readOnlyNote)
    return task + composioNote + capability
        + (browser ? browserGuidance(profileURL: profileURL) : "")
}

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
                                 task: agentPrompt(task: task, fullAccess: fullAccess,
                                                   browser: effectiveBrowser,
                                                   profileURL: Profile.validStoredProfileURL),
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

# Form Filling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Agent: renew my passport at gov.uk" — Debby opens a browser, fills the form from the user's own documents, stops before anything irreversible, and asks.

**Architecture:** Neither the browsing nor the document reading is written in Swift; both are the `claude` CLI's job, reached through a second MCP gateway (`playwright`) alongside the `composio` one already registered. Swift holds the session id, watches the agent's output for a `NEED:` line, shows a confirm gate, and resumes the same CLI session on approval.

**Tech Stack:** Swift 5.9+, macOS 14+, Foundation / AppKit / SwiftUI only. No third-party packages. Playwright MCP runs via `npx`, registered once into the `claude` CLI's own config.

## Global Constraints

- **Zero Swift dependencies.** `Package.swift` gains nothing.
- **Tests are `assert` calls inside `runSelfCheck()`** in `Sources/HeyDebby/main.swift`. There is no XCTest target; creating one is a defect.
- **The verification command is `./build.sh`** — debug build, `.build/debug/HeyDebby --selfcheck`, release build, codesign. A failed assert aborts it.
- **New Swift files go in `Sources/HeyDebby/`.**
- **Editor/SourceKit "cannot find X in scope" errors are stale index artifacts.** Trust `./build.sh`.
- **Requires the `claude` CLI.** `codex exec` has no `--session-id` / `--resume`, so pause-and-continue cannot be expressed on it. When `Claude.CLI.isLoggedIn` is false the browser toggle is disabled and `browserNote` is never added; agents behave exactly as they do today. No fallback path, and no per-task classification anywhere.
- **The confirm gate has no off switch**, and the *agent full access* toggle must not bypass it. `fullAccess` changes the CLI's permission flags; it does not change `browserNote`.
- **`profile.json` is mode `0600`, lives in Application Support, never in `~/Documents`** (which syncs to iCloud), and is wipeable from settings.
- **Swift never inlines profile values into a prompt.** A passport number on a command line is visible to every process via `ps`. The prompt carries the file path only; the agent reads it with its own `Read` tool.

---

### Task 1: `NEED:` detection

The gate's trigger. Pure string handling, fully testable, and nothing else depends on the rest of the feature.

**Files:**
- Create: `Sources/HeyDebby/Need.swift`
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `struct NeedScanner` with `mutating func feed(_ chunk: String) -> String?` — returns the text after the first `NEED:` marker once its line is complete, nil otherwise.

**Why a scanner and not a regex over the whole output.** Agent output arrives in pipe-sized chunks that split anywhere, including through the middle of the word `NEED`. The same class of bug the reply parser had: a marker straddling a chunk boundary must still be found.

- [ ] **Step 1: Write the failing tests**

Add to `runSelfCheck()` in `Sources/HeyDebby/main.swift`:

```swift
    // --- NEED: the agent's confirm gate ---
    func scanAll(_ chunks: [String]) -> String? {
        var s = NeedScanner()
        var found: String?
        for c in chunks { if let n = s.feed(c), found == nil { found = n } }
        return found
    }
    assert(scanAll(["Filling the form…\nNEED: Ready to submit — £88.50. Submit?\n"])
           == "Ready to submit — £88.50. Submit?", "NEED must be found in a multi-line chunk")
    // The bug this scanner exists for: a pipe can split anywhere.
    assert(scanAll(["Filling…\nNE", "ED: the code from your phone\n"])
           == "the code from your phone", "a marker split across chunks must still be found")
    assert(scanAll(["done\nNEED: first question\nNEED: second question\n"])
           == "first question", "the first NEED wins; the agent stops after printing one")
    assert(scanAll(["all done, no gate here\n"]) == nil, "no marker means no gate")
    // A line that merely mentions the word is not a marker: it must start the line.
    assert(scanAll(["I NEED: nothing\n"]) == nil, "NEED must start its line")
    // Unterminated: the agent exits without a trailing newline more often than not.
    assert(scanAll(["NEED: last line, no newline"]) == nil,
           "an incomplete line is not yet a marker — flush() covers this case")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error, `cannot find 'NeedScanner' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HeyDebby/Need.swift`:

```swift
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
```

- [ ] **Step 4: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 5: Add the flush test**

The last assertion above documents that an unterminated line is not yet a marker. Prove `flush()` is what completes it:

```swift
    var fs = NeedScanner()
    _ = fs.feed("NEED: last line, no newline")
    assert(fs.flush() == "last line, no newline", "flush must catch the unterminated last line")
    assert(fs.flush() == nil, "flush twice must not fire twice")
```

Run `./build.sh` and confirm green.

- [ ] **Step 6: Commit**

```bash
git add Sources/HeyDebby/Need.swift Sources/HeyDebby/main.swift
git commit -m "feat: NeedScanner finds the agent's confirm marker across chunk boundaries"
```

---

### Task 2: Session id and resume in `agentCommand`

**Files:**
- Modify: `Sources/HeyDebby/AgentRunner.swift`
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `agentCommand(backend:task:screenshotPath:fullAccess:session:resume:)` — `session: String? = nil`, `resume: Bool = false`. Existing call sites keep working through the defaults.

**Read first.** `agentCommand` builds a shell command string. `--allowedTools` is variadic: it must stay last, and the prompt must precede it, or it swallows what follows. The existing selfcheck asserts exactly that and must keep passing.

- [ ] **Step 1: Write the failing tests**

```swift
    // --- agent session id / resume ---
    let uuid = "0F8E4B10-3C2A-4D5E-9F01-2A3B4C5D6E7F"
    let first = agentCommand(backend: "claude", task: "renew my passport",
                             screenshotPath: nil, fullAccess: false, session: uuid)
    assert(first.contains("--session-id \(uuid)"), "first run must pin the session: \(first)")
    assert(!first.contains("--resume"), "the first run resumes nothing")
    assert(first.range(of: "--allowedTools")!.lowerBound
           > first.range(of: "'renew my passport'")!.lowerBound,
           "--allowedTools is variadic and must stay after the prompt")

    let again = agentCommand(backend: "claude", task: "Confirmed — proceed.",
                             screenshotPath: nil, fullAccess: false,
                             session: uuid, resume: true)
    assert(again.contains("-r \(uuid)"), "the resume run must reattach: \(again)")
    assert(!again.contains("--session-id"), "resume replaces --session-id, never both")
    assert(again.range(of: "--allowedTools")!.lowerBound
           > again.range(of: "'Confirmed")!.lowerBound,
           "--allowedTools stays last on resume too")

    // codex has no equivalent; it must be untouched by either flag.
    let cx = agentCommand(backend: "codex", task: "hi", screenshotPath: nil,
                          fullAccess: false, session: uuid)
    assert(!cx.contains(uuid), "codex takes no session id: \(cx)")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error — `agentCommand` has no `session:` parameter.

- [ ] **Step 3: Add the parameters**

In `Sources/HeyDebby/AgentRunner.swift`, extend the signature and the claude branch. The codex branch ignores both, since `codex exec` has no equivalent:

```swift
func agentCommand(backend: String, task: String, screenshotPath: String?, fullAccess: Bool,
                  session: String? = nil, resume: Bool = false) -> String {
```

In the claude branch, build the session flag before the return and place it before the prompt:

```swift
    // `-r <id>` reattaches to the paused run; `--session-id <id>` names a fresh one so we
    // can reattach later without parsing a session id back out of the CLI's output.
    var sessionFlag = ""
    if let s = session { sessionFlag = resume ? " -r \(s)" : " --session-id \(s)" }
```

and thread `sessionFlag` into both existing `return` statements immediately after `claude -p`, keeping `--allowedTools` last:

```swift
    if fullAccess {
        return "claude -p\(sessionFlag) --dangerously-skip-permissions \(shellQuote(prompt))"
    }
    return "claude -p\(sessionFlag) \(shellQuote(prompt)) --allowedTools mcp__composio Read Glob Grep"
```

If Task 4 of the app-control plan has already added `Bash(osascript:*)` to that allowlist, keep it — do not drop tools while editing this line.

- [ ] **Step 4: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output. The pre-existing `agentCommand` assertions must still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/HeyDebby/AgentRunner.swift Sources/HeyDebby/main.swift
git commit -m "feat: agentCommand can pin and resume a claude session"
```

---

### Task 3: The confirm gate in `AppState` and the notch

**Files:**
- Modify: `Sources/HeyDebby/AppState.swift` (`runAgent`, `agentTick`, new state)
- Modify: `Sources/HeyDebby/UI.swift` (✓ / ✕ controls)
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Consumes: `NeedScanner` (Task 1), `agentCommand(…session:resume:)` (Task 2).
- Produces: `AppState.pendingNeed: String?` (`@Published`), `AppState.confirmNeed()`, `AppState.cancelNeed()`.

**Read first.** `runAgent(_:)` in `AppState.swift` spawns the CLI and streams output through `agentTick(_:)`, which shows only the newest line in the notch. `onDone` currently sets `agentLine` to "✅ agent done" or "❌ agent exited (n)". The gate changes what `onDone` shows when a `NEED:` was seen. Only one gate exists at a time.

- [ ] **Step 1: Write the failing test**

```swift
    // The gate is a resume of the SAME session, with the confirmation as the new prompt.
    let gateCmd = agentCommand(backend: "claude", task: "Confirmed — proceed.",
                               screenshotPath: nil, fullAccess: false,
                               session: "ABC", resume: true)
    assert(gateCmd.contains("-r ABC") && gateCmd.contains("'Confirmed — proceed.'"),
           "confirming must reattach and say so: \(gateCmd)")
    // Full access must not change the gate's shape — it is not an escape hatch from it.
    let gateFull = agentCommand(backend: "claude", task: "Confirmed — proceed.",
                                screenshotPath: nil, fullAccess: true,
                                session: "ABC", resume: true)
    assert(gateFull.contains("-r ABC"), "full access still resumes the same session")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: assertion failure or compile error depending on Task 2's state; if Task 2 is already committed this passes immediately — in that case say so and move to Step 3, since the wiring below is what this task really adds.

- [ ] **Step 3: Add the gate state**

In `Sources/HeyDebby/AppState.swift`, beside `agentLine` / `agentBusy`:

```swift
    @Published var pendingNeed: String?   // the agent stopped and asked; ✓/✕ are showing
    private var needSession: String?      // the CLI session ✓ reattaches to
    private var needScanner = NeedScanner()
```

Add `pendingNeed != nil` to the `open` computed property so the notch stays open while a gate is showing — a gate nobody can see is a hang.

- [ ] **Step 4: Wire the scanner into the run**

In `runAgent(_:)`, generate and keep a session id, reset the scanner, and pass the id through:

```swift
        let session = UUID().uuidString
        needSession = session
        needScanner = NeedScanner()
        pendingNeed = nil
```

Pass `session: session` to `AgentRunner.run` (which forwards it to `agentCommand`; add the parameter there the same way).

In `agentTick(_:)`, feed the scanner before the existing newest-line handling:

```swift
        if let need = needScanner.feed(chunk) { pendingNeed = need }
```

In the `onDone` handler, flush the scanner first, then choose what to show:

```swift
                if let late = self.needScanner.flush() { self.pendingNeed = late }
                self.agentBusy = false
                if let need = self.pendingNeed {
                    self.agentLine = "❓ \(need)"
                    if self.voiceReplies { self.voice.speak(need) }
                } else {
                    self.agentLine = code == 0 ? "✅ agent done" : "❌ agent exited (\(code))"
                    self.agentFade()
                }
```

Do not call `agentFade()` when a gate is showing — the question must stay until answered.

- [ ] **Step 5: Add confirm and cancel**

```swift
    /// ✓ — reattach to the paused session and let it finish the step it stopped before.
    func confirmNeed() {
        guard let session = needSession else { return }
        pendingNeed = nil
        runAgent("Confirmed — proceed.", resumeSession: session)
    }

    /// ✕ — the session is abandoned. The browser window stays open; the user takes over.
    func cancelNeed() {
        pendingNeed = nil
        needSession = nil
        agentLine = ""
    }
```

Give `runAgent` a `resumeSession: String? = nil` parameter: when set, it reuses that id and passes `resume: true` rather than generating a new one, and it must NOT reset `needSession` — the same session can gate more than once in a long form.

- [ ] **Step 6: Clear the gate when the session ends**

A stale gate that resumes a dead session is worse than none. In `newChat()` / `dismiss()` and wherever running agents are terminated, add:

```swift
        pendingNeed = nil
        needSession = nil
```

- [ ] **Step 7: Add the notch controls**

In `Sources/HeyDebby/UI.swift`, where the *I did it* button is rendered, add a branch showing ✓ and ✕ when `state.pendingNeed != nil`, calling `state.confirmNeed()` and `state.cancelNeed()`. Match the surrounding button styling exactly rather than inventing new styling. The ✓ label should read *Confirm* and ✕ *Cancel*, since "I did it" means something different here.

- [ ] **Step 8: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 9: Verify the gate by hand, without a browser**

Run: `open build/HeyDebby.app`, then say: *"agent: print exactly this line and then stop — NEED: does the gate work?"*
Expected: the notch shows ❓ does the gate work? with Confirm / Cancel, Debby speaks it, and it does not fade. Cancel clears it. This exercises the whole gate with no MCP server involved.

- [ ] **Step 10: Commit**

```bash
git add Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "feat: NEED: confirm gate with session resume"
```

---

### Task 4: The profile

**Files:**
- Create: `Sources/HeyDebby/Profile.swift`
- Modify: `Sources/HeyDebby/AppState.swift` (scan action)
- Modify: `Sources/HeyDebby/UI.swift` (settings rows)
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `enum Profile` with `static let url: URL`, `static func write(_ json: String) throws`, `static func extractJSON(_ raw: String) -> String?`, `static var lastScanned: Date?`, `static func delete()`.

- [ ] **Step 1: Write the failing tests**

```swift
    // --- Profile: pulling JSON out of a model's answer ---
    assert(Profile.extractJSON("```json\n{\"a\":1}\n```") == "{\"a\":1}",
           "markdown fences must come off")
    assert(Profile.extractJSON("Here you go:\n{\"a\":1}\nhope that helps") == "{\"a\":1}",
           "prose either side must come off")
    assert(Profile.extractJSON("{\"a\":{\"b\":2}}") == "{\"a\":{\"b\":2}}",
           "nested braces must survive")
    assert(Profile.extractJSON("no json here") == nil, "garbage yields nil, not a guess")
    assert(Profile.extractJSON("{not valid json}") == nil,
           "syntactically invalid JSON must be rejected, not written to disk")
    assert(Profile.extractJSON("") == nil, "empty output yields nil")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error, `cannot find 'Profile' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HeyDebby/Profile.swift`:

```swift
import Foundation

/// The user's own details, extracted from their documents once and reused.
///
/// Application Support rather than ~/Documents: that folder syncs to iCloud, and this
/// file holds a passport number. `0600` because it holds a passport number.
enum Profile {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("HeyDebby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }()

    /// Models wrap JSON in fences and chat around it. Take the outermost braces and
    /// validate — writing unvalidated text would turn a chatty reply into a broken profile.
    static func extractJSON(_ raw: String) -> String? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"),
              open < close else { return nil }
        let candidate = String(raw[open...close])
        guard (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil
        else { return nil }
        return candidate
    }

    static func write(_ json: String) throws {
        try json.data(using: .utf8)?.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static var lastScanned: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}
```

- [ ] **Step 4: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 5: Add the scan**

In `Sources/HeyDebby/AppState.swift`:

```swift
    var docsFolder: String { UserDefaults.standard.string(forKey: "docsFolder") ?? "" }

    /// One agent run that reads the user's documents and prints JSON. It goes through
    /// AgentRunner.spawn rather than the one-shot shellOutput helper because a scan of a
    /// documents folder runs for minutes, and a notch with no ticker looks hung.
    ///
    /// The agent is never granted Write: it prints, Swift writes the file.
    func scanDocuments() {
        let folders = docsFolder.isEmpty
            ? "~/Documents, ~/Desktop and ~/Downloads"
            : docsFolder
        let prompt = """
        Read the documents in \(folders) and extract the personal details a form would ask \
        for — full name, date of birth, passport number and expiry, driving licence, \
        national insurance or social security number, address, phone, email. \
        Print ONE JSON object and nothing else, shaped like \
        {"passport_number":{"value":"K1234567","source":"~/Documents/passport.pdf"}}. \
        Use snake_case keys. Omit anything you cannot find — never guess a value. \
        Do not write any files.
        """
        agentBusy = true
        agentLine = "📇 reading your documents…"
        var out = ""
        AgentRunner.spawn(cliPathPrefix + "claude -p \(shellQuote(prompt)) "
                          + "--allowedTools Read Glob Grep",
                          onOutput: { chunk in
                              out += chunk
                              Task { @MainActor in self.agentTick(chunk) }
                          },
                          onDone: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.agentBusy = false
                guard let json = Profile.extractJSON(out) else {
                    self.agentLine = "❌ couldn't read your documents"
                    return
                }
                do {
                    try Profile.write(json)
                    self.agentLine = "✅ profile saved"
                } catch {
                    self.agentLine = "❌ \(error.localizedDescription)"
                }
                self.agentFade()
            }
        })
    }
```

- [ ] **Step 6: Add the settings rows**

In `Sources/HeyDebby/UI.swift`, in the settings panel: a **Documents folder** row using `NSOpenPanel` with `canChooseDirectories = true`, `canChooseFiles = false`, storing the chosen path in the `docsFolder` `@AppStorage` key; a **Scan now** button calling `state.scanDocuments()`; a line reading `Last scanned <date>` from `Profile.lastScanned` or *Never*; and a **Delete profile** button calling `Profile.delete()`. Match the surrounding rows' styling.

Include this caption verbatim — the user is entitled to know what is on disk:

```swift
                Text("Saved to Application Support, readable only by you. It holds real "
                     + "ID numbers — delete it any time.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 7: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 8: Verify by hand**

Run the app, pick a folder with one or two documents in it, and press *Scan now*. Then check the file:

```bash
ls -l ~/Library/Application\ Support/HeyDebby/profile.json
```

Expected: mode `-rw-------`, and valid JSON inside. Report the actual mode string.

- [ ] **Step 9: Commit**

```bash
git add Sources/HeyDebby/Profile.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "feat: document scan writes a 0600 profile.json"
```

---

### Task 5: Browser control

**Files:**
- Modify: `Sources/HeyDebby/AgentRunner.swift` (`browserNote`, allowlist)
- Modify: `Sources/HeyDebby/AppState.swift` (registration action)
- Modify: `Sources/HeyDebby/UI.swift` (toggle)
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Consumes: `agentCommand(…session:resume:)` (Task 2), `Profile.url` (Task 4).
- Produces: `let browserNote: String`; `AppState.browserControl: Bool`; `AppState.enableBrowserControl()`.

- [ ] **Step 1: Write the failing test**

```swift
    // Browser tasks need the playwright gateway; the allowlist stays last.
    let br = agentCommand(backend: "claude", task: "book a slot", screenshotPath: nil,
                          fullAccess: false, session: "S1")
    assert(br.contains("mcp__playwright"), "the browser gateway must be allowed: \(br)")
    // Do not assert on the last token — the app-control plan appends to this list.
    assert(br.range(of: "--allowedTools")!.lowerBound
           > br.range(of: "'book a slot'")!.lowerBound,
           "--allowedTools is variadic and must stay after the prompt")
    // The note must forbid the three things Debby must never do, in words the model reads.
    assert(browserNote.contains("NEED:"), "the note must define the gate marker")
    assert(browserNote.lowercased().contains("captcha"), "the note must forbid CAPTCHAs")
    assert(browserNote.contains(Profile.url.path),
           "the note carries the profile PATH, never its contents — argv is world-readable")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error, `cannot find 'browserNote' in scope`.

- [ ] **Step 3: Write the note**

In `Sources/HeyDebby/AgentRunner.swift`, beside `composioNote`:

```swift
/// Appended to every agent task while browser control is on. No per-task classification:
/// a note costs less than code that guesses which tasks are form tasks.
///
/// The profile PATH is passed, never its contents — a passport number on a command line
/// is visible to every process on the machine via `ps`.
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
```

- [ ] **Step 4: Add it to the run, and the gateway to the allowlist**

In `agentCommand`'s claude branch, add `mcp__playwright` to `--allowedTools`. In `AgentRunner.run`, append `browserNote` alongside `composioNote` when browser control is on — pass that as a parameter rather than reading `UserDefaults` from `AgentRunner`, keeping the runner free of app settings:

```swift
    static func run(backend: String, task: String, screenshotPath: String?, fullAccess: Bool,
                    session: String? = nil, resume: Bool = false, browser: Bool = false,
                    onOutput: @escaping (String) -> Void,
                    onDone: @escaping (Int32) -> Void) -> Process? {
        let full = task + composioNote + (browser ? browserNote : "")
```

- [ ] **Step 5: Add the toggle and registration**

In `Sources/HeyDebby/AppState.swift`:

```swift
    var browserControl: Bool { UserDefaults.standard.bool(forKey: "browserControl") }

    /// Registers the Playwright MCP server with the claude CLI. A persistent user-data-dir
    /// keeps the user's logins between runs; the window is visible so they can intervene.
    /// This writes to the CLI's global config, so the server is visible to the user's other
    /// claude sessions too — the settings copy says so.
    func enableBrowserControl() {
        let dir = Profile.url.deletingLastPathComponent()
            .appendingPathComponent("browser").path
        let cmd = "claude mcp add playwright -- npx -y @playwright/mcp@latest "
                + "--user-data-dir \(shellQuote(dir))"
        agentBusy = true
        agentLine = "🌐 setting up the browser…"
        Task {
            do {
                _ = try await shellOutput(cmd)
                agentLine = "✅ browser ready"
            } catch {
                UserDefaults.standard.set(false, forKey: "browserControl")
                agentLine = "❌ \(error.localizedDescription)"
            }
            agentBusy = false
            agentFade()
        }
    }
```

Pass `browser: browserControl` from `runAgent` into `AgentRunner.run`.

- [ ] **Step 6: Add the settings toggle**

In `Sources/HeyDebby/UI.swift`, beside the other agent toggles, a toggle bound to the `browserControl` key that calls `state.enableBrowserControl()` when switched on. Disable it entirely when the `claude` CLI is not signed in, with the caption *"needs the claude CLI — run `claude` once to sign in"*. Otherwise caption it:

```swift
                Text("Debby fills forms in a real browser and stops for your OK before "
                     + "anything is submitted. Registers a browser tool with the claude "
                     + "CLI, so your other claude sessions can see it too.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 7: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 8: Verify by hand, on something harmless**

Enable the toggle, then: *"agent: go to example.com and tell me what the page says"*.
Expected: a browser window opens and Debby reports the text. Then try a real form with a review step — a site you do not mind abandoning — and confirm she stops at the review page with a Confirm gate rather than submitting. **Do not test this on a real passport application.**

- [ ] **Step 9: Commit**

```bash
git add Sources/HeyDebby/AgentRunner.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "feat: browser control via Playwright MCP, gated by NEED:"
```

---

## Notes for the implementer

- **The gate is the feature.** If a review finds any path where the agent can submit, pay, or log in without a `NEED:` first, that is a Critical finding regardless of how small the diff to fix it is. The *agent full access* toggle changes CLI permission flags; it must not remove `browserNote`.
- **Never inline profile values into a prompt or a command line.** `ps` is world-readable. The note carries `Profile.url.path` and nothing else; Task 5's assertion pins that.
- **`npx` may not exist** on a machine without Node. `claude mcp add` then fails, and Step 5's `catch` turns the toggle back off — verify that path by temporarily renaming `npx` if you want to see it.
- **Task 3 Step 9 tests the whole gate without a browser.** Use it first; if the gate is broken, nothing downstream is worth debugging.

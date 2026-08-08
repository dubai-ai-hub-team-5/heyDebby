# Automation Security Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make HeyDebby's browser, Mac automation, document scanning, and profile storage enforce safe behavior in code without adding approval dialogs.

**Architecture:** A pure browser policy evaluates Playwright tool requests and is exposed to Claude as an app-scoped `PreToolUse` hook. Model-written AppleScript is replaced by a closed Codable action enum. Profile scans use a private logging mode and persist only typed data whose source files resolve inside the selected scan roots.

**Tech Stack:** Swift 5.9, SwiftPM, Foundation, AppKit/SwiftUI, Claude Code CLI hooks, Playwright MCP `0.0.79`, the existing `--selfcheck` test harness.

## Global Constraints

- Do not add an approval prompt before ordinary automated actions.
- Leave the visible browser open when the user must complete an action themselves.
- Do not add a runtime dependency.
- Do not change global Claude settings or affect Claude sessions launched outside HeyDebby.
- Preserve the current SwiftPM, self-check, and ad-hoc app build workflow.
- Treat the profile and scanned document output as private data.
- Browser-enabled runs must not use `--dangerously-skip-permissions`.
- Unknown automation inputs fail closed.

## File map

- Create `Sources/HeyDebby/BrowserPolicy.swift`: pure Playwright allow/deny policy, Claude hook event/result models, and per-run settings JSON.
- Modify `Sources/HeyDebby/AgentRunner.swift`: browser-aware command construction, settings-path injection, run cleanup, and output logging policy.
- Modify `Sources/HeyDebby/AppState.swift`: pinned Playwright setup/removal, browser-run policy settings, typed action playback, private scans, and privacy deletion.
- Modify `Sources/HeyDebby/Beats.swift`: `AppAction` decoding and `ACTION:` beats; remove arbitrary `RUN:` parsing.
- Modify `Sources/HeyDebby/Claude.swift`: document only the closed `ACTION:` contract.
- Modify `Sources/HeyDebby/Control.swift`: fixed AppleScript templates from `AppAction`.
- Modify `Sources/HeyDebby/Profile.swift`: strict typed profile schema, source containment, validated atomic writes, and privacy deletion.
- Modify `Sources/HeyDebby/Log.swift`: `0700`/`0600` permissions, testable log destination, and deletion.
- Modify `Sources/HeyDebby/UI.swift`: truthful settings copy and surfaced delete/setup/remove failures.
- Modify `Sources/HeyDebby/main.swift`: focused self-check assertions for every new boundary and hook CLI mode dispatch.

---

### Task 1: Pure browser policy and Claude hook mode

**Files:**
- Create: `Sources/HeyDebby/BrowserPolicy.swift`
- Modify: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `enum BrowserPolicyDecision: Equatable { case allow; case deny(String) }`
- Produces: `BrowserPolicy.evaluate(toolName: String, input: [String: Any]) -> BrowserPolicyDecision`
- Produces: `BrowserPolicy.evaluateHookJSON(_ data: Data) -> Data`
- Produces: `BrowserPolicy.settingsJSON(executablePath: String) throws -> Data`
- Consumes: Claude hook input keys `hook_event_name`, `tool_name`, and `tool_input`.

- [ ] **Step 1: Add failing policy assertions to `runSelfCheck()`**

Add fixtures that assert:

```swift
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__browser_snapshot", input: [:]) == .allow)
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__browser_navigate",
                              input: ["url": "https://example.com/form"]) == .allow)
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__browser_fill_form", input: [
    "fields": [["name": "Full name", "type": "textbox", "ref": "e12", "value": "Debby User"]]
]) == .allow)
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__browser_click",
                              input: ["element": "Submit application", "ref": "e90"]).isDenied)
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__browser_fill_form", input: [
    "fields": [["name": "Password", "type": "textbox", "ref": "e13", "value": "secret"]]
]).isDenied)
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__browser_evaluate",
                              input: ["function": "() => document.cookie"]).isDenied)
assert(BrowserPolicy.evaluate(toolName: "mcp__playwright__future_tool", input: [:]).isDenied)
```

Also assert malformed hook JSON produces a deny result and settings JSON contains a `PreToolUse` matcher for `mcp__playwright` plus the current executable's `--browser-policy-hook` command.

- [ ] **Step 2: Run the self-check and verify RED**

Run: `swift run HeyDebby --selfcheck`

Expected: compilation fails because `BrowserPolicy` and `BrowserPolicyDecision.isDenied` do not exist.

- [ ] **Step 3: Implement the minimal pure policy**

Create `BrowserPolicy.swift` with:

```swift
enum BrowserPolicyDecision: Equatable {
    case allow
    case deny(String)
    var isDenied: Bool { if case .deny = self { true } else { false } }
}

enum BrowserPolicy {
    static func evaluate(toolName: String, input: [String: Any]) -> BrowserPolicyDecision
    static func evaluateHookJSON(_ data: Data) -> Data
    static func settingsJSON(executablePath: String) throws -> Data
}
```

Use exact safe-tool names for snapshot, screenshot, navigate, navigate-back, resize, tabs, wait-for, select-option, hover, and safe fill/click/type operations. Require HTTP(S) for navigation. Reject secret field labels/types, irreversible click labels, evaluate/run-code, file-upload, dialog, downloads, CAPTCHA terms, unknown names, malformed arrays, and missing required labels/refs. Return Claude's documented `hookSpecificOutput` with `permissionDecision` set to `allow` or `deny`; denial reason tells the agent to leave the browser open for the user.

In `main.swift`, before app startup, read stdin and print the result when `--browser-policy-hook` is present. Do not log hook input or output.

- [ ] **Step 4: Run the self-check and direct hook fixtures and verify GREEN**

Run:

```bash
swift run HeyDebby --selfcheck
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"mcp__playwright__browser_click","tool_input":{"element":"Submit","ref":"e1"}}' | swift run HeyDebby --browser-policy-hook
```

Expected: `selfcheck OK`; direct hook output contains `"permissionDecision":"deny"` and no submitted payload value is echoed.

- [ ] **Step 5: Commit the policy slice**

```bash
git add Sources/HeyDebby/BrowserPolicy.swift Sources/HeyDebby/main.swift
git commit -m "feat: enforce browser tool policy"
```

### Task 2: Per-run browser capability and pinned setup

**Files:**
- Modify: `Sources/HeyDebby/AgentRunner.swift`
- Modify: `Sources/HeyDebby/AppState.swift`
- Modify: `Sources/HeyDebby/UI.swift`
- Modify: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Consumes: `BrowserPolicy.settingsJSON(executablePath:)` from Task 1.
- Changes: `agentCommand(..., browser: Bool = false, settingsPath: String? = nil) -> String`.
- Changes: `AgentRunner.run(...)` creates and cleans the temporary settings file for browser-enabled Claude runs.
- Produces: `let playwrightMCPVersion = "0.0.79"`.

- [ ] **Step 1: Write failing command/setup assertions**

Assert browser-off Claude commands omit both `mcp__playwright` and `--settings`; browser-on commands include both; browser-on plus `fullAccess: true` omits `--dangerously-skip-permissions`; non-browser full-access remains unchanged. Assert the registration command contains `@playwright/mcp@0.0.79` and no `@latest`.

- [ ] **Step 2: Run the self-check and verify RED**

Run: `swift run HeyDebby --selfcheck`

Expected: browser-off still contains Playwright or the new parameters/constants are absent.

- [ ] **Step 3: Implement conditional capability and settings lifecycle**

Update `agentCommand` to build tools as `mcp__composio Read Glob Grep`, appending `mcp__playwright` only for `browser == true`. When browser is true, require a settings path and append `--settings \(shellQuote(settingsPath))` before the variadic `--allowedTools`. Apply dangerous permission bypass only when `fullAccess && !browser`.

Have `AgentRunner.run` write settings data to a unique file in `FileManager.default.temporaryDirectory` at mode `0600`, pass its path, and remove it in every completion/launch-failure path. If creation fails, report the error and do not launch Claude.

Pin setup to `@playwright/mcp@0.0.79`. Make removal awaited, restore the toggle on failure, and show the error. Update settings copy to say safe filling is automatic and final/secret actions are left in the open browser, without an approval/resume claim.

- [ ] **Step 4: Run focused checks and verify GREEN**

Run: `swift run HeyDebby --selfcheck`

Expected: `selfcheck OK` with all command-shape assertions passing.

- [ ] **Step 5: Commit browser integration**

```bash
git add Sources/HeyDebby/AgentRunner.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "feat: gate browser access per run"
```

### Task 3: Typed local Mac actions

**Files:**
- Modify: `Sources/HeyDebby/Beats.swift`
- Modify: `Sources/HeyDebby/Claude.swift`
- Modify: `Sources/HeyDebby/Control.swift`
- Modify: `Sources/HeyDebby/Lesson.swift`
- Modify: `Sources/HeyDebby/AppState.swift`
- Modify: `Sources/HeyDebby/AgentRunner.swift`
- Modify: `Sources/HeyDebby/UI.swift`
- Modify: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `enum AppAction: Equatable, Decodable` with `.setVolume(Int)`, `.changeVolume(Int)`, and `.media(app: MediaApp, command: MediaCommand)`.
- Changes: `Beat.run(String)` to `Beat.action(AppAction)`.
- Changes: `Control.arguments(for action: AppAction) -> [String]` and `Control.run(_ action: AppAction, ...)`.

- [ ] **Step 1: Write failing action/parser/template assertions**

Test valid `ACTION:` JSON for volume bounds and Music/Spotify media commands. Test rejection of -1/101 absolute volume, -21/21 delta, unknown apps/commands, extra properties, `RUN:` lines, and raw AppleScript. Assert `Control.arguments` contains only fixed templates and the Claude command never includes `Bash(osascript:*)`.

- [ ] **Step 2: Run the self-check and verify RED**

Run: `swift run HeyDebby --selfcheck`

Expected: `AppAction` and `.action` are missing and the old raw-run assertions conflict.

- [ ] **Step 3: Implement the closed action protocol**

Decode an intermediate strict payload with keys `type`, `value`, `app`, and `command`; verify the exact allowed-key set for each action before constructing `AppAction`. Replace `RUN:` recognition with `ACTION:` JSON decoding and never log rejected payload values.

Map actions to fixed argv statements:

```swift
.setVolume(60)       -> ["-e", "set volume output volume 60"]
.changeVolume(-10)   -> a fixed script that clamps current output volume to 0...100
.media(.music, .next)-> ["-e", "tell application \"Music\" to next track"]
```

Update the player and AppState callback to pass the enum. Replace prompt examples/copy with the JSON contract. Remove `Bash(osascript:*)` from every Claude allowlist.

- [ ] **Step 4: Run the self-check and verify GREEN**

Run: `swift run HeyDebby --selfcheck`

Expected: `selfcheck OK`; searches for executable raw protocol paths are empty:

```bash
rg -n 'case run|RUN:|Bash\(osascript' Sources/HeyDebby
```

Only historical test text, if any, may remain; production prompt and command paths must be absent.

- [ ] **Step 5: Commit typed actions**

```bash
git add Sources/HeyDebby/Beats.swift Sources/HeyDebby/Claude.swift Sources/HeyDebby/Control.swift Sources/HeyDebby/Lesson.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/AgentRunner.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "feat: replace AppleScript with typed actions"
```

### Task 4: Private process logging and protected log files

**Files:**
- Modify: `Sources/HeyDebby/AgentRunner.swift`
- Modify: `Sources/HeyDebby/Log.swift`
- Modify: `Sources/HeyDebby/AppState.swift`
- Modify: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `enum ProcessLogging { case standard; case privateOutput(label: String) }`.
- Changes: `AgentRunner.spawn(..., logging: ProcessLogging = .standard, ...)`.
- Produces: testable `DebbyLog.configureForTesting(url:)` and `DebbyLog.delete() throws`.

- [ ] **Step 1: Write failing privacy and permission assertions**

Use a unique temporary log URL. Spawn `/bin/zsh -lc` output containing a sentinel under `.privateOutput(label: "profile scan")`, wait for completion, and assert the callback receives the sentinel while the log contains only the generic label/exit and not the command or sentinel. Assert the log parent mode is `0700`, file mode is `0600`, and rotation preserves `0600`.

- [ ] **Step 2: Run the self-check and verify RED**

Run: `swift run HeyDebby --selfcheck`

Expected: new logging mode/test destination APIs are absent or the sentinel appears in the log.

- [ ] **Step 3: Implement private output and permissions**

Branch every `DebbyLog.write/raw` site inside `spawn` on `ProcessLogging`. For private output, log only the literal `RUN profile scan` and `EXIT profile scan 0` shape, substituting the supplied label and actual exit status. Keep callback buffering unchanged. Create directories then set `0700`; create/rotate files atomically then set `0600`. Make the test destination override lock-protected and reset it after each assertion.

Pass `.privateOutput(label: "profile scan")` from `scanDocuments()`.

- [ ] **Step 4: Run the self-check and verify GREEN**

Run: `swift run HeyDebby --selfcheck`

Expected: `selfcheck OK`; the private sentinel is absent from the temporary log.

- [ ] **Step 5: Commit private logging**

```bash
git add Sources/HeyDebby/AgentRunner.swift Sources/HeyDebby/Log.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/main.swift
git commit -m "fix: keep profile scans out of logs"
```

### Task 5: Strict profile schema and source containment

**Files:**
- Modify: `Sources/HeyDebby/Profile.swift`
- Modify: `Sources/HeyDebby/AppState.swift`
- Modify: `Sources/HeyDebby/UI.swift`
- Modify: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Produces: `struct ProfileField: Codable, Equatable { let value: String; let source: String }`.
- Produces: `Profile.validateAndEncode(_ raw: String, allowedRoots: [URL]) throws -> Data`.
- Changes: `Profile.write(_ data: Data) throws` and `Profile.deletePrivateData() throws`.

- [ ] **Step 1: Write failing schema and filesystem assertions**

Build a temporary root with a real document, a sibling directory, and a symlink inside the root pointing outside. Assert a valid lower-snake-case field referencing the real file is re-encoded. Assert rejection for scalar entries, empty objects, extra properties, uppercase/space keys, empty/control-character/overlong values, relative sources, missing sources, sibling traversal, symlink escape, empty profile, malformed JSON, and a profile with one valid plus one invalid entry.

- [ ] **Step 2: Run the self-check and verify RED**

Run: `swift run HeyDebby --selfcheck`

Expected: `validateAndEncode` and typed field definitions are absent.

- [ ] **Step 3: Implement typed validation and atomic persistence**

Extract the outer JSON object, reject non-dictionary roots, check exact entry keys `{value, source}`, validate limits, expand `~`, standardize and resolve symlinks, require a regular existing file, and perform component-aware containment against standardized/resolved allowed roots. Encode `[String: ProfileField]` with sorted keys and pretty printing.

Write only fully validated data using `.atomic`, then enforce `0600`. In `scanDocuments()`, pass the exact default roots or selected custom root into validation. Keep the old profile untouched on any error.

Implement `deletePrivateData()` to remove profile and log, treating missing files as success but propagating other filesystem errors. Update the button to call AppState so errors can be shown and the last-scanned UI refreshes.

- [ ] **Step 4: Run the self-check and verify GREEN**

Run: `swift run HeyDebby --selfcheck`

Expected: `selfcheck OK` with all schema and containment fixtures passing.

- [ ] **Step 5: Commit validated profiles**

```bash
git add Sources/HeyDebby/Profile.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "fix: validate profile data and provenance"
```

### Task 6: Remove obsolete browser confirmation behavior and integrate errors

**Files:**
- Modify: `Sources/HeyDebby/AgentRunner.swift`
- Modify: `Sources/HeyDebby/AppState.swift`
- Modify: `Sources/HeyDebby/UI.swift`
- Modify: `Sources/HeyDebby/main.swift`
- Modify: `README.md` if its feature description mentions confirmation or arbitrary AppleScript.

**Interfaces:**
- Consumes: browser policy denial from Task 1; no new public interface.
- Preserves: `NEED:` for non-browser missing-information agent flows only.

- [ ] **Step 1: Write failing integration assertions**

Assert `browserNote` tells the model that denied actions are completed by the user directly and does not instruct it to print `NEED:` for final submission. Assert UI copy contains no claim that HeyDebby resumes an irreversible browser action after confirmation. Assert setup/removal/delete failure handlers leave toggles and status text truthful.

- [ ] **Step 2: Run the self-check and verify RED**

Run: `swift run HeyDebby --selfcheck`

Expected: old `browserNote` and settings text still mention `NEED:`/OK confirmation.

- [ ] **Step 3: Remove the obsolete browser gate path**

Rewrite `browserNote` as non-security guidance: use profile data, never request secret fields, and stop when the policy denies a tool. Do not emit `NEED:` for irreversible browser actions. Keep the generic `NeedScanner` and confirmation UI for unrelated agent questions. Update user-facing copy and error handling to match actual automatic/denied behavior.

- [ ] **Step 4: Run the self-check and verify GREEN**

Run: `swift run HeyDebby --selfcheck`

Expected: `selfcheck OK`; browser-specific confirmation assertions are absent and generic NEED tests remain green.

- [ ] **Step 5: Commit integration cleanup**

```bash
git add Sources/HeyDebby/AgentRunner.swift Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift README.md
git commit -m "fix: hand off denied browser actions"
```

### Task 7: Full verification and security review

**Files:**
- Modify only files required by failures found during verification.

**Interfaces:**
- Consumes all prior tasks; produces no new runtime interface.

- [ ] **Step 1: Run the complete project verification**

```bash
./build.sh
.build/debug/HeyDebby --selfcheck
git diff --check
```

Expected: both self-check runs print `selfcheck OK`; release build and ad-hoc signing finish with exit code 0; `git diff --check` prints nothing.

- [ ] **Step 2: Run static security searches**

```bash
rg -n '@latest|Bash\(osascript|RUN:|dangerously-skip-permissions.*playwright' Sources README.md
rg -n 'DebbyLog\.(write|raw).*profile|privateOutput' Sources/HeyDebby
git grep -nE '(CLOUDFLARE_API_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY|ghp_|sk-ant-|sk-proj-)'
```

Expected: no dynamic Playwright version, raw AppleScript grant/protocol, browser permission bypass, or committed credential. Private scan call sites are visible and intentional.

- [ ] **Step 3: Exercise the hook executable directly**

Send safe snapshot/fill fixtures and denied submit/password/evaluate/unknown fixtures to `.build/debug/HeyDebby --browser-policy-hook`. Expected: safe fixtures return allow; denied fixtures return deny; no fixture values appear in `~/Library/Logs/HeyDebby/debby.log`.

- [ ] **Step 4: Review the complete diff against the approved design**

Check every design requirement, inspect `git status --short`, and confirm no unrelated files changed. Fix any gap test-first and rerun Steps 1–3.

- [ ] **Step 5: Commit verification fixes if needed**

```bash
git add -u Sources/HeyDebby README.md
git commit -m "fix: close automation hardening gaps"
```

If verification required no edits, do not create an empty commit.

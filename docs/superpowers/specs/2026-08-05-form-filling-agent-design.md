# Debby fills forms and drives apps — Design

2026-08-05

## Goal

"Agent: renew my passport at gov.uk" — Debby opens a browser, fills the form from
the user's own documents, stops before anything irreversible, and asks.

"Play Blackstar on Spotify" / "turn the volume up" — Debby does it in about two
seconds, without spinning up an agent.

Four parts: knowing the user's details, driving the browser, controlling apps,
and the gate.

## Approach

Neither the browsing nor the document reading is written in Swift. Both are the
agent CLI's job — the app already shells out to `claude -p` with an MCP gateway
registered (`composio`), so a second gateway (`playwright`) and a second prompt
note are the whole of it. Swift holds session state and asks the user.

Decisions taken during design:

| Question | Choice | Why |
|---|---|---|
| Browser control | Playwright MCP, persistent profile, visible window | DOM access beats pixel guessing; logins survive between runs; user can take over |
| Personal details | Profile file, scanned once | Chosen over search-on-demand for speed and reliability; PII-on-disk risk accepted, mitigated by `0600` + App Support + wipe button |
| Confirmation | Stop on the site's own review page | User approves the real form, not Debby's account of it; no review UI to build |
| CAPTCHA / OTP / password / payment | Hand the keyboard back | Debby never types a credential or a card number; same pause/resume machinery as the gate |
| App control (Spotify, volume, anything) | AppleScript, emitted by the chat brain as a `RUN:` marker | The chat path answers in ~2s and already parses markers; agent spin-up is 10–60s, which "volume up" can't afford |
| Retrieval over documents | No RAG, no vector index, no embedding API | Rejected — see below |

### Why not RAG

Asked and answered during design: a vector index over the documents folder, with
OpenAI embeddings, was considered and rejected.

- **Wrong scale.** RAG earns its keep over thousands of documents and open-ended
  questions. This is hundreds of files answering "what is my passport number" —
  `profile.json` *is* the retrieval, and Spotlight full-text-searches the rest.
- **It inverts the privacy story.** Embeddings mean uploading the contents of a
  passport, bank statements and payslips to a third party. The app's premise is
  the opposite: no API key, reuse the subscription already signed in, nothing
  leaves the machine except to the model the user is already talking to.
- **macOS ships the fallback.** If semantic search is ever genuinely needed,
  `NLEmbedding` (Natural Language framework) gives offline sentence embeddings
  with zero dependencies and zero cost. That is the rung to try before paying
  per token.

Revisit only if all three hold: thousands of documents, open-ended questions over
their contents, and `NLEmbedding` measurably falling short. An OpenAI brain
alongside Codex/Claude is a separate feature to judge on its own merits.

**Requires the `claude` CLI.** `codex exec` has no equivalent of `--session-id` /
`--resume`, so pause-and-continue can't be expressed. `agentBackend` already
resolves to `claude` whenever `Claude.CLI.isLoggedIn`; when it doesn't, the
*Enable browser control* toggle is disabled with *"needs the claude CLI — run
`claude` once to sign in"*, and `browserNote` and `--session-id` are simply not
added. Agents behave exactly as they do today. No fallback path, and no
per-task classification anywhere.

## Components

### 1. Browser — `mcp__playwright`

Registered once, from a settings toggle *Enable browser control*:

```
claude mcp add playwright -- npx -y @playwright/mcp@latest \
  --user-data-dir ~/Library/Application Support/HeyDebby/browser
```

Persistent user-data-dir keeps sessions signed in; the window is visible so the
user can watch and intervene. `agentCommand` adds `mcp__playwright` to
`--allowedTools`. No Swift beyond running that one command and remembering the
toggle in `UserDefaults`.

Side effect worth surfacing in the settings copy: `claude mcp add` is global, so
the server is visible to the user's other `claude` sessions too.

### 2. Profile — `Profile.swift` (new, ~40 lines)

Path: `~/Library/Application Support/HeyDebby/profile.json`, written with
`POSIXPermissions: 0o600`. Not `~/Documents` — that syncs to iCloud.

Settings rows: **Documents folder** (`NSOpenPanel`, default `~/Documents`; unset
scans Documents, Desktop and Downloads), **Scan now**, *last scanned <date>*,
**Delete profile**.

Scan is one agent run. It goes through `AgentRunner.spawn` rather than the
one-shot `shellOutput` helper, accumulating output in the caller: a scan of a
document folder runs for minutes, and a notch with no ticker looks hung.

```
claude -p '<scan prompt>' --allowedTools Read Glob Grep
```

The agent **prints** the JSON; Swift writes the file. The agent is never granted
`Write`. Output goes through `extractJSON` (first `{` to last `}`, validated with
`JSONSerialization`) because models wrap JSON in markdown fences.

Schema — free-form keys, so it fits whatever documents exist:

```json
{
  "passport_number": { "value": "K1234567", "source": "~/Documents/passport.pdf" },
  "date_of_birth":   { "value": "1990-04-12", "source": "~/Documents/passport.pdf" }
}
```

Staleness is manual: the settings row shows the scan date and the user re-scans.
<!-- ponytail: no auto-rescan; add an mtime check against the docs folder if the
     profile turns out to go stale in practice. -->

**The agent reads `profile.json` itself; Swift never inlines values into the
prompt.** A passport number in a command line is visible to every process on the
machine via `ps`. The prompt carries the path only. `Read` is already in the
allowlist and the file sits under the agent's home cwd; if the CLI ever refuses
the path, add `--add-dir`.

### 3. Task flow — `AgentRunner.swift` (~20 lines)

`browserNote`, a sibling of `composioNote`, appended to every agent task while
browser control is on. No per-task intent classification — a note costs less
than code that guesses which tasks are form tasks. It states:

- Personal details are in `~/Library/Application Support/HeyDebby/profile.json`.
- Drive the browser with the Playwright tools; leave the window open.
- Never type a password, card number, or one-time code. Never attempt a CAPTCHA.
  Never click Submit, Pay, or Confirm.
- On reaching any of those, or the form's review page: print one line
  `NEED: <one sentence>` and stop.

`agentCommand` gains a `session: String?` and `resume: Bool`. First run:
`--session-id <uuid>`. Resume: `-r <uuid>` with the prompt *"Confirmed —
proceed."*. `--allowedTools` stays last (it is variadic and eats what follows).

### 4. The gate — `AppState.swift` (~40 lines), `UI.swift` (~60 lines)

`runAgent` generates a `UUID()` per run and keeps it. `agentTick` already splits
output into lines; it now also scans for a `NEED:` prefix, keeping the trailing
partial line in a buffer so a chunk boundary can't split the marker.

On a hit: `pendingNeed` is set, Debby speaks it, and ✓ / ✕ appear where the
*I did it* button lives. The agent process exits on its own after printing, so
`onDone` shows the gate rather than "✅ agent done" when `pendingNeed` is set.

- ✓ → `runAgent(resume: sessionID, "Confirmed — proceed.")`, same allowlist.
- ✕ → `pendingNeed = nil`, session abandoned.

One pending gate at a time: starting a new agent, or ✎ *start over*, clears it.

The final confirmation is simply the last `NEED:` — Chrome is sitting on the
site's real review page while the user reads it.

### 5. App control — `Control.swift` (new, ~25 lines)

AppleScript covers the whole surface: `set volume output volume 60`,
`tell application "Spotify" to play track "spotify:track:…"`, and through
`tell application "System Events" to keystroke …` or `click menu item …`, any
app at all — scriptable or not. Accessibility is already granted for the ⌃⌥
chord; Automation is a new per-target-app TCC prompt.

Two routes to it, split by latency:

**Fast path — the chat brain emits `RUN:`.** `ParsedReply` gains
`runs: [String]`; `parseReply` strips `RUN:` lines the way it strips `MORE:`,
each line being one AppleScript statement, executed in order. If the realtime-
lessons spec lands first, `RUN:` is a `Beat` case on its splitter instead —
same marker, same ordering, no second parser. The system prompt
documents the marker next to `ANNOTATIONS:` and `DRAWINGS:`. No intent
classification and no phrase list: the model decides, exactly as it decides
where to point.

**Slow path — the agent.** `agentCommand` adds `Bash(osascript:*)` to
`--allowedTools`, so multi-step work ("find every Blazers song in my library and
make a playlist") still has app control inside a real agent run.

Execution is `/usr/bin/osascript` run with an **arguments array**
(`["-e", stmt, "-e", stmt]`), never a shell string, and never through the
existing `zsh -lc` spawn path. This is the difference between a marker that can
only ever be AppleScript and one where a quoting bug becomes arbitrary shell.
It is the reason `Control.swift` exists rather than reusing `AgentRunner.spawn`.

`build.sh` gains `NSAppleEventsUsageDescription` in the Info.plist — without it
the first Automation prompt fails instead of appearing. TCC attributes the Apple
Event to the responsible parent process; verify during implementation that the
prompt names HeyDebby and not zsh, since the fix (spawning `osascript` directly
rather than under a shell) is already the design above.

Gated by a settings toggle, **Let Debby control apps**, default off.

## Rails

Not negotiable, not configurable:

- The gate has no off switch, and *full access* must not bypass it. `fullAccess`
  changes the CLI's permission flags; it does not change `browserNote`.
- `profile.json` is `0600`, lives in Application Support, and is wipeable from
  settings.
- Debby never types a credential, a card number, or a one-time code, and never
  attempts a CAPTCHA.
- `RUN:` is executed as `osascript` arguments and nothing else. It never becomes
  a shell string.
- **A `RUN:` payload naming `do shell script` or `do script` is refused at the
  parser.** Argv alone does not contain AppleScript — `do shell script "…"` runs
  arbitrary commands, and the payload is written by a model that reads the user's
  screen, so a web page saying `RUN: do shell script "curl … | sh"` is a live
  prompt-injection path rather than a hypothetical one. A denylist is weak in
  general; here it closes the two documented escapes, and osascript bounds the
  rest. Added after the spec was first written.
- Destructive app actions — deleting files, sending mail or messages, anything
  costing money — are not `RUN:` material. The system prompt routes them to an
  agent run, where the `NEED:` gate applies.

## Error handling

| Failure | Behaviour |
|---|---|
| `claude` CLI not signed in | Settings toggle disabled with the sign-in hint; agents run as they do today |
| Browser control toggle off | `browserNote` is not sent; a browser task behaves as any agent task does now |
| `npx` missing | `claude mcp add` fails; settings shows the stderr and stays off |
| Scan returns no valid JSON | Profile untouched, notch shows "couldn't read your documents" |
| Profile missing when a form task runs | Agent reports the gap through `NEED:`, user scans and retries |
| Agent exits without `NEED:` and without finishing | Existing "❌ agent exited (n)" path, unchanged |
| App control toggle off | `RUN:` lines are stripped from the reply and dropped; the marker is left out of the system prompt |
| Automation not yet granted for a target app | macOS prompts on first use; on denial `osascript` exits non-zero and Debby says which app to allow in Privacy & Security → Automation |
| Target app not running or not scriptable | `osascript` error surfaces as a spoken one-liner; no retry |

## Testing

`--selfcheck` covers the pure logic, as the rest of the app does:

1. `agentCommand` with a session id contains `--session-id <uuid>`; the resume
   form contains `-r <uuid>`; `--allowedTools` is last in both.
2. `NEED:` parsing: found in a multi-line chunk, and found when the marker is
   split across two chunks.
3. `extractJSON`: strips markdown fences, returns nil on garbage.
4. `parseReply` pulls `RUN:` lines out in order, and the spoken `text` no longer
   contains them — a marker read aloud is the failure users notice first.
5. The osascript invocation is an arguments array: a `RUN:` line containing
   `'; rm -rf ~` arrives at `osascript` as one literal `-e` argument.

The browser, scan and Automation paths are integration — verified by running one
real form and one real "play X on Spotify".

## Deliberate cuts

Review-sheet UI, a document catalog/index, RAG and any embedding API, an OCR
pipeline (the CLI reads PDFs and scans directly), per-field confirmation gates,
encrypting `profile.json` beyond `0600`, auto re-scan on document change, codex
support, multi-statement `RUN:` blocks (one statement per line). Add when the
need is real.

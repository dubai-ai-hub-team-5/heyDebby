# HeyDebby — Technical Specification

A native macOS "AI buddy that lives in the notch." Hold **⌃⌥** and talk about
what's on your screen; Debby answers out loud, points at things, runs background
agents, fills forms, and drives your apps. Native Swift, **zero third-party
dependencies**.

This document covers the problem, the architecture, why each tool was chosen, why
it was buildable in a six-hour window, and what v2 looks like. For install/run
instructions see the [README](./README.md).

---

## 1. The problem

Getting help with something on your Mac means leaving your Mac: screenshot it,
paste it into a chat window, type the question, read the answer, then look back and
forth trying to map "the button top-right" onto your actual screen. The context —
what's in front of you — is exactly what a chat window throws away.

[HeyClicky](https://heyclicky.com) framed the fix: press a key, talk, and an AI
that already sees your screen answers out loud and *points at things*. HeyDebby is
a faithful, native clone of that idea, extended in three directions:

1. **Answer + point.** "What does this error mean?" → spoken answer plus a pulsing
   pointer on the exact UI element, drawn on a click-through overlay.
2. **Teach, in sync.** A step-by-step walkthrough or a whiteboard-style lesson
   where each shape appears *as* Debby narrates it — not all at the end.
3. **Do.** "Turn the volume up" happens in ~2s; "agent: renew my passport at
   gov.uk" spins up a real background agent that fills the form from your own
   documents and stops before anything irreversible to ask you.

The constraints that shape every decision below:

- **Privacy-first.** Screenshots are never archived (one overwritten temp file,
  captured only at ask-time). No API key required — reuse the AI subscription
  you're already signed into, so nothing leaves the machine except to the model
  you're already talking to.
- **No window.** Every control lives in the notch. No chat log, no typing.
- **Native and lazy.** Every feature should map onto an OS API or a CLI that
  already exists, so almost no novel infrastructure is written.

---

## 2. Architecture

### 2.1 Shape of the app

A menu-bar / notch-only app (`LSUIElement`), single executable target built with
SwiftPM. One `@MainActor` orchestrator (`AppState`) owns the state machine; every
other file is a focused capability it calls into.

```
                       ┌───────────────────────────────────────────┐
   ⌃⌥ chord ──────────▶│                 AppState                    │
   (Hotkey.swift)       │  @MainActor state machine + brain routing  │
                        │  listen → capture → ask → speak/draw/run    │
   mic ───▶ Speech ────▶│  agent routing · confirm gate · lessons     │
   (SFSpeechRecognizer) └───┬───────┬──────────┬───────────┬──────────┘
                            │       │          │           │
                    Capture │  Brains          │  Agents   │  Beats/Lessons
                (ScreenCapture│ (per-turn)      │(AgentRunner)│ (BeatSplitter
                    Kit)     │                  │           │  + LessonPlayer)
                            ▼       ▼          ▼           ▼
                    debby-shot.jpg  Codex/Claude/    claude -p / codex exec   Speech (TTS)
                    (temp)          OpenAI/Gemini    + MCP gateways           + UI overlay
                                                     (composio, playwright)    (pointers/shapes)
```

### 2.2 Core loop

`Hotkey → Speech (STT) → Capture → Brain → parse → Speech (TTS) + overlay draw`.

1. **Trigger** — `Hotkey.swift` watches the global `flagsChanged` event stream for
   the ⌃⌥ chord (hold-to-talk; quick-tap latches on and silence sends). A
   modifier-only chord can't be a Carbon hot key, which is why it reads the event
   stream and needs Accessibility permission.
2. **Listen** — `Speech.swift` runs live `SFSpeechRecognizer` transcription and
   auto-finalizes after ~1.6s of silence.
3. **See** — `Capture.swift` grabs a fresh screenshot via ScreenCaptureKit
   (`SCScreenshotManager`), excluding Debby's own windows, optionally cropped to a
   user-drawn focus area. It becomes base64 (for API brains) and one overwritten
   temp file (for CLI brains). Never archived.
4. **Ask** — `AppState` picks a brain (§2.3) and sends history + question +
   screenshot with a shared system prompt (`Claude.systemPrompt`).
5. **Parse** — the reply is a stream of one-marker-per-line beats (§2.5):
   prose to speak, `POINT:`/`DRAW:` to render, `RUN:` to execute, `MORE:` to
   continue a multi-step walkthrough.
6. **Answer** — `Speech.swift` speaks (best installed English `AVSpeechSynthesis`
   voice); `UI.swift` draws pulsing pointers and shapes on a transparent,
   click-through overlay that auto-hides after 8s.

### 2.3 Brains — five backends, one interface

`resolveBackend()` in `AppState.swift` resolves the user's choice, defaulting to
**Auto**: prefer whichever subscription is already signed in (Codex, then Claude
CLI), and only fall back to a paid API key.

| Brain | Transport | Auth | Notes |
|---|---|---|---|
| **Codex** (ChatGPT plan) | Direct HTTPS to the Codex responses endpoint | Reuses the Codex CLI's OAuth token (`~/.codex/auth.json`) | OpenHands-style; model from `~/.codex/config.toml`; token never leaves the machine except to OpenAI |
| **Claude CLI** (Claude plan) | Shells out to `claude` | Reuses the signed-in `claude` CLI | Screenshot passed as a file path; `--allowedTools Read` scoped to that one image |
| **Claude API** | Anthropic Messages API | `ANTHROPIC_API_KEY` / settings | Default `claude-sonnet-5` |
| **Gemini** | Google Generative Language API | `GOOGLE_API_KEY` / `GEMINI_API_KEY` / settings | Vision; default `gemini-3.1-flash-lite`, thinking budget 0 |
| **OpenAI** | OpenAI Responses API, **streaming** | `OPENAI_API_KEY` / settings | GPT-5.6 family (default `gpt-5.6-luna`); the only streamed brain — powers realtime lessons |

Each brain is a small `enum` (`Codex.swift`, `Claude.swift`, `OpenAI.swift`,
`Gemini.swift`) exposing one `send`/`stream` function. The system prompt is shared,
so switching brains changes nothing about how replies are parsed or rendered.

### 2.4 Agents — the slow, powerful path

"agent …" routes to `AgentRunner.swift`, which spawns the `claude -p` or
`codex exec` CLI as a `Process` and streams stdout into the notch (newest line
tickers). This is where tools and MCP live; the app owns none of that machinery.

- **Sandbox by default.** Codex agents run read-only; the *full access* toggle adds
  `--dangerously-bypass-approvals-and-sandbox`. Claude agents run scoped
  (`--allowedTools mcp__composio Read Glob Grep Bash(osascript:*)`); *full access*
  adds `--dangerously-skip-permissions`.
- **MCP gateways.** Two remote gateways are registered into the CLI's own config:
  **Composio** (`connect.composio.dev/mcp`) for 500+ apps (Gmail, Calendar, Slack,
  Notion, GitHub…), and **Playwright** (`npx @playwright/mcp`) for browser control
  with a persistent, visible profile.
- **The confirm gate (`NEED:`).** `Need.swift`'s `NeedScanner` watches streamed
  output for a `NEED:` line (buffered across pipe-chunk boundaries). On a hit,
  `AppState` opens a `Gate` bound to that exact CLI session id; ✓ resumes it
  (`claude -r <id>` "Confirmed — proceed."), ✕ abandons it. The gate has **no off
  switch** and *full access* cannot bypass it — Debby never types a credential,
  card number, or one-time code, and never attempts a CAPTCHA.

### 2.5 Beats, lessons, and app control

The wire format is one marker per line, inline with prose, instead of a trailing
JSON block. `Beats.swift`'s `BeatSplitter` turns a reply — streamed in fragments or
arriving whole — into an ordered list:

```swift
enum Beat { case say(String), draw(ShapeSpec), point(Annotation), run(String) }
```

`Lesson.swift`'s `LessonPlayer` consumes beats strictly in order: `.say` speaks and
**waits** for the end-of-utterance callback before releasing what follows;
`.draw`/`.point`/`.run` fire immediately and continue. That waiting is the whole
sync mechanism — streamed text arrives far faster than speech, so a sentence's shape
lands right as it's spoken instead of all shapes appearing in the first two seconds.
With OpenAI streaming, time-to-first-word is ~1s instead of ~12s.

**App control** is the `RUN:` beat — one AppleScript statement, run via
`Control.swift` as `/usr/bin/osascript` with an **arguments array**
(`["-e", stmt]`), never a shell string. The fast path (chat brain emits `RUN:`)
answers in ~2s; the slow path is `Bash(osascript:*)` inside an agent run.

### 2.6 Form filling — no Swift, no RAG

`Profile.swift` holds the user's details as `~/Library/Application
Support/HeyDebby/profile.json`, mode `0600`, written once from an agent scan of the
user's documents folder (the agent *prints* JSON; Swift validates and writes; the
agent is never granted `Write`). During a form task the agent is told the file's
**path only** — a passport number on a command line is visible to every process via
`ps` — and reads it with its own `Read` tool.

RAG / an embedding index was explicitly rejected (see §3): this is hundreds of files
answering "what's my passport number," so `profile.json` *is* the retrieval and
Spotlight covers the rest. It also inverts the privacy story, and `NLEmbedding`
ships offline if semantic search is ever genuinely needed.

### 2.7 Security rails (not configurable)

- The `NEED:` gate has no off switch; *full access* changes CLI permission flags,
  not the gate.
- `RUN:` is executed only as `osascript` arguments; a payload naming
  `do shell script` / `do script` is **refused at the parser** — the payload is
  written by a model reading the user's screen, so a web page saying
  `RUN: do shell script "curl … | sh"` is a live prompt-injection path.
- `profile.json` is `0600`, in Application Support (never `~/Documents`, which
  syncs to iCloud), and wipeable from settings.
- Destructive actions (delete, send mail, spend money) are never `RUN:` material;
  the prompt routes them to an agent run where the gate applies.

### 2.8 File map

| File | Responsibility |
|---|---|
| `main.swift` | Bootstrap, `AppDelegate`, menu-bar item, `runSelfCheck()`, `--notchcheck`/`--codex-check`/`--gemini-check` |
| `AppState.swift` | `@MainActor` orchestration, `resolveBackend`, brain routing, confirm `Gate`, agent lifecycle |
| `Hotkey.swift` | ⌃⌥ talk chord via the global `flagsChanged` stream |
| `Speech.swift` | STT (silence auto-finalize) + TTS |
| `Capture.swift` | ScreenCaptureKit screenshot → JPEG base64 + temp file, focus-area crop |
| `Claude.swift` | Anthropic API + `claude` CLI, shared system prompt, `parseReply` |
| `Codex.swift` / `OpenAI.swift` / `Gemini.swift` | The other brains |
| `AgentRunner.swift` | Background CLI agents, `agentCommand` (session id / resume, allowlists) |
| `Beats.swift` | `Beat` + `BeatSplitter` (streaming-safe, one marker per line) |
| `Lesson.swift` | `LessonPlayer` — draw/speech sync engine |
| `Control.swift` | `RUN:` AppleScript via `osascript` argv |
| `Need.swift` | `NeedScanner` — the confirm-gate trigger |
| `Profile.swift` | `profile.json` read/write/validate, `0600` |
| `Log.swift` | `~/Library/Logs/HeyDebby/debby.log`, front-trimmed at 2 MB |
| `UI.swift` | The notch, settings, click-through overlay |

### 2.9 Testing

There is no XCTest target by design. Pure logic is asserted inside `runSelfCheck()`
in `main.swift` and run by `build.sh` against the **debug** binary (`assert` is
compiled out of release builds). Covered: `BeatSplitter` chunk-boundary invariance,
sentence splitting (`3.14` doesn't split), malformed-shape dropping, `NeedScanner`
across chunk boundaries, `agentCommand` flag ordering, the `RUN:` shell-out refusal,
`Control` argv escaping, `Profile.extractJSON`, and `resolveBackend`. Everything
else is OS integration, verified by running.

---

## 3. Tool rationale

| Decision | Choice | Why |
|---|---|---|
| Language / stack | **Native Swift, zero deps** | Every feature maps onto a first-party API; it's both the most faithful *and* the least code. Electron is heavy and un-Mac-like; Python/pyobjc has a fragile permissions story. `Package.swift` has no dependencies and gains none. |
| Screenshots | **ScreenCaptureKit** | Modern, can exclude own windows, per-display, croppable — no legacy `CGWindowList`. |
| Voice in/out | **SFSpeechRecognizer + AVSpeechSynthesizer** | On-device, free, no streaming-STT vendor. |
| Talk trigger | **Global `flagsChanged` monitor** | A modifier-only chord (⌃⌥) can't be a Carbon hot key. Costs an Accessibility grant; keeps the menu bar working underneath. |
| AI auth | **Reuse the CLI's OAuth token / shell out to the CLI** | The privacy premise: no API key, nothing leaves the machine except to the model the user already pays for. API keys are the fallback, not the default. |
| Agents | **`claude -p` / `codex exec` as subprocesses** | The CLIs already own tools, sandboxing, and MCP. Re-implementing any of it in Swift would be slower and worse. |
| App integrations / browser | **MCP gateways (Composio, Playwright)** | Registered once into the CLI's config; the app writes ~one command, not an integration per app. DOM access beats pixel-guessing; a persistent profile keeps logins. |
| Lessons | **Direct HTTPS streaming (OpenAI Responses)** | Measured: `claude -p` takes ~12s to first token (fixed CLI + MCP startup), streaming HTTPS ~1–2s. The CLI stays for agents (which need its tools); lessons leave it. |
| Draw/speech sync | **Beat queue driven by `didFinish`** | Exact, and it deletes the old `~33 chars/sec` estimate. |
| App control | **AppleScript via `osascript` argv** | Covers volume, Spotify, menus, and — via System Events — any app at all, with no per-app SDK. Argv (not a shell string) means a quoting bug can never become arbitrary shell. |
| Retrieval | **No RAG / no embeddings** | Wrong scale (hundreds of files, not thousands), and uploading passport/bank contents to a third party inverts the privacy story. `NLEmbedding` is the offline rung to try first if semantic search is ever needed. |
| Tests | **`assert` in `--selfcheck`** | The logic worth testing is pure and small; a full XCTest harness is ceremony this doesn't need. |

---

## 4. Six-hour feasibility

The build fits a ~6-hour window precisely *because* almost nothing novel is
written — the "native and lazy" constraint is a scheduling strategy, not just an
aesthetic one.

**Why it's tractable in six hours:**

- **Every capability is a thin wrapper over an existing API or binary.** Screenshot
  = one `SCScreenshotManager` call. Voice = two AVFoundation classes. Agents,
  browsing, and 500+ app integrations = shelling out to a CLI that already does all
  of it. There is no server, no database, no auth flow to build, and no dependency
  graph to manage — reusing the CLI's OAuth token removes the single biggest
  time-sink (sign-in UX).
- **The hard-but-small parts are pure functions.** Marker parsing (`BeatSplitter`),
  the confirm-gate trigger (`NeedScanner`), flag ordering (`agentCommand`), and
  coordinate mapping are the only genuinely tricky logic — and each is a page of
  code covered by an `assert` in `--selfcheck`, so they're written test-first and
  stay correct as the rest changes.
- **One verification command.** `./build.sh` does debug build → selfcheck → release
  build → codesign. Tight loop, no CI to stand up.

**What the six hours buy, and in what order:**

1. Notch UI + ⌃⌥ chord + screenshot + one brain + speak = the core loop.
2. Overlay drawing (`POINT:`/`DRAW:`) + the shared system prompt.
3. Background agents via the CLI + Composio gateway.
4. The additive features (streaming lessons, app control, form filling) each land
   as a marker + a small file, reusing the same splitter, prompt, and CLI plumbing.

**What was deliberately cut to fit** (and why it's safe to cut): typing / chat
history, wake-word always-listening, a configurable hotkey, a per-display notch,
streaming for non-lesson brains, a review-sheet UI, an OCR pipeline, and Windows.
None are load-bearing for the demo, and each has a clear later home.

The honest caveats a six-hour build carries: TCC permission grants reset on every
ad-hoc-signed rebuild (a real cert fixes it); coordinate accuracy is model- and
display-dependent and was tuned by hand; and everything outside the pure-logic
tests is verified by running, not by an automated suite.

---

## 5. What v2 looks like

Grouped by theme; each item is currently a deliberate cut, listed with what would
justify building it.

**Latency & model quality**
- Streaming for every brain (only OpenAI streams today), so any brain gets ~1s
  time-to-first-word.
- Re-tune screen-coordinate guidance per model; GPT-5.6's geometry accuracy is
  unverified vs the Gemini-tuned prompt. `gpt-5.6-terra`/`-sol` are a settings flip.
- Codex support for the form-filling gate — blocked today because `codex exec` has
  no `--session-id`/`--resume`, so pause-and-continue can't be expressed.

**Retrieval & documents (only if the scale arrives)**
- Offline semantic search via `NLEmbedding` — the zero-cost, zero-dependency rung
  before any embedding API. Revisit RAG only if *all three* hold: thousands of
  documents, open-ended questions over their contents, and `NLEmbedding` measurably
  falling short.
- Auto-rescan of the profile on document-folder changes (mtime check) instead of a
  manual "Scan now."

**Interaction**
- Wake-word ("hey debby") always-listening, a configurable hotkey, and a notch per
  display.
- Word-level draw anchoring (fire a shape mid-sentence) if sentence granularity
  ever feels coarse; an abbreviation-aware sentence splitter ("e.g.") for the same.
- Typing / a chat history, if voice-only ever proves limiting.

**Trust & polish**
- A real signing identity so Accessibility / Screen Recording grants survive
  rebuilds.
- A review-sheet UI for form confirmation (today the gate reuses the site's own
  review page), and per-field gates if the single final gate proves too coarse.
- Encrypting `profile.json` beyond `0600`; a proper log rotator.
- Multi-statement `RUN:` blocks (one statement per line today).

The governing rule for all of it: **add when the need is real.** Every cut above is
recorded so v2 is a menu, not a rediscovery.

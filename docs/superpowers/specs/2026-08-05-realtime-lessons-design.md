# Realtime lessons — draw while talking — Design

2026-08-05

## Problem

A Pythagoras lesson today: draw everything, then talk about it, then re-screenshot,
then draw again. Slow, and the drawing never matches what is being said.

Measured, on this machine:

| Path | Time to emit one token |
|---|---|
| `claude -p`, current config (14 MCP servers registered) | **12.4s** |
| `claude -p --strict-mcp-config` | **6.6s** |
| Direct HTTPS to a model API | ~1–2s |

The prompt whose entire output was the word `ok`. None of that 12.4s is the model
thinking. The 7–15s lesson steps in `~/Library/Logs/HeyDebby/debby.log` are ~12s
of fixed CLI overhead plus 1–3s of generation. MCP server startup accounts for
5.8s of it, and one registered server (`daydream`) refuses connections on every
invocation.

So the latency fix is leaving the CLI, and the sync fix is streaming. They are
different problems and both need doing.

## Decisions

| Question | Choice | Why |
|---|---|---|
| Where lesson turns run | Direct HTTPS, not the CLI | 12.4s → ~2s. The CLI stays for **agents**, which need its tools and MCP |
| Which API | OpenAI Responses API, streaming | User's call, made with the measurements in hand |
| Drawing format | Inline `DRAW:` lines replace the trailing `DRAWINGS:` block | Emission order becomes narration order |
| Draw/speech sync | Beat queue driven by `didFinish` | Replaces an estimated `33 chars/sec`; exact, and it deletes code |
| Retrieval | No RAG | No corpus exists; it addresses neither latency nor sync |

RAG was considered and rejected here as it was in the form-filling spec: nothing
is being looked up, so retrieval has nothing to retrieve.

## Components

### 1. `OpenAI.swift` (new, ~90 lines)

`POST https://api.openai.com/v1/responses`, `"stream": true`. Key from settings
with an `OPENAI_API_KEY` environment fallback, mirroring `apiKey` and
`geminiApiKey`. Settings gains an **OpenAI** brain and a model field beside
`codexModel` / `geminiModel`.

Models are the GPT-5.6 family: **`gpt-5.6-luna`** (default — the fast, cheap one,
which is what a twelve-step lesson wants), `gpt-5.6-terra`, `gpt-5.6-sol`.

Streaming with no dependency: `URLSession.bytes(for:)` gives an `AsyncSequence`,
and `.lines` splits the SSE frames. Keep lines prefixed `data: `, decode the
envelope, accumulate `delta` from events of type `response.output_text.delta`,
finish on `response.completed`. Errors arrive as an `error` event or a non-2xx
status before any frame.

The screenshot goes in as base64 image input, **first turn only** (see §5).

### 2. `DRAW:` replaces the `DRAWINGS:` block

The model emits one shape per line, inline, between the sentences that describe
them:

```
The hypotenuse is the long side, opposite the right angle.
DRAW: {"tool":"line","points":[{"x":0.3,"y":0.7},{"x":0.6,"y":0.4}],"color":"orange"}
Now the square built on it.
DRAW: {"tool":"square","points":[{"x":0.3,"y":0.7},{"x":0.6,"y":0.4}],"color":"blue"}
```

`extractBlock("DRAWINGS:", …)` in [Claude.swift](../../../Sources/HeyDebby/Claude.swift)
is deleted. `ShapeSpec` is unchanged — a `DRAW:` line is exactly one element of
the array that used to be sent at the end.

`ANNOTATIONS:` becomes `POINT:` on the same one-per-line footing, for the same
reason. `MORE:` is unchanged.

The form-filling spec adds a `RUN:` marker for AppleScript. It is already
one-per-line, so under this design it is simply another beat — see §3. Whichever
spec lands second inherits the other's parser rather than adding one.

### 3. `BeatSplitter` — the parser (new, ~40 lines)

```swift
enum Beat { case say(String), draw(ShapeSpec), point(Annotation) }
struct BeatSplitter { mutating func feed(_ chunk: String) -> [Beat] }
```

Holds a partial-line buffer, because SSE deltas split mid-token. On each complete
line: a `DRAW:` / `POINT:` prefix decodes to that beat; anything else is prose,
accumulated until a sentence ends — `.`, `!` or `?` **followed by whitespace or
end of input**, which is also why `3.14` doesn't split.

Non-streaming backends (Claude CLI, Claude API, Gemini) feed their whole reply to
the same splitter in one call. A complete reply is a stream that arrived at once,
so there is one format and one parser, not two paths.
<!-- ponytail: naive sentence split; "e.g." starts a new utterance. Costs a
     slightly short pause when spoken. Add an abbreviation list only if it grates. -->

### 4. `LessonPlayer` — the sync engine (new, ~50 lines)

The feature itself. A queue of beats, appended to as the stream arrives, consumed
strictly in order:

- `.say(s)` → `voice.enqueue(s)`, then **wait for `onSpeakEnd`** before the next beat.
- `.draw` / `.point` → render immediately, continue without waiting.

Consecutive draws land together; the following sentence waits for them to be on
screen. That waiting is the whole mechanism: streamed text arrives far faster than
speech, so without it every shape would appear inside the first two seconds while
Debby is still reading sentence one.

Speech starts at the first completed sentence, so time-to-first-word is under a
second rather than 12.

`Speech.swift` needs no change. `speak` calls `stop()` first
([Speech.swift:132](../../../Sources/HeyDebby/Speech.swift)), which would cancel a
queue — but the player only ever speaks when nothing is speaking, so that `stop()`
is a no-op and `currentUtterance` keeps meaning what the delegate guards assume.
`onSpeakEnd` already fires from both `didFinish` and `didCancel`; `AppState` chains
it into the player.

Cancellation: a new question bumps the existing `chatGeneration` guard, which
drops queued beats, calls `voice.stop()`, and cancels the URLSession task.

### 5. Two deletions and a skipped screenshot

- The `33 chars/sec` estimate and the `range(of: orig.label)` search at
  [AppState.swift:410](../../../Sources/HeyDebby/AppState.swift) go away.
  Annotations are `.point` beats now; position comes from emission order.
- The per-shape reveal delay in the `drawings` block goes away for the same reason.
- Auto-advance turns capture no screenshot: the only thing that changed on screen
  is Debby's own drawing, and those coordinates are already in the history. With
  interleaving a whole lesson usually streams as one response, so `MORE:` survives
  only for lessons that outrun the output limit.

## Error handling

| Failure | Behaviour |
|---|---|
| No OpenAI key | Same prompt-for-settings path as the other brains |
| Non-2xx before any frame | Status and body shown as a chat message; nothing spoken |
| Stream drops mid-lesson | Beats already queued still play out; then "the connection dropped" |
| A `DRAW:` line is malformed JSON | That line is skipped, the lesson continues — one bad shape must not kill a lesson |
| Model emits no `DRAW:` at all | Plain spoken answer, exactly as today |
| TTS off (`voiceReplies` false) | Beats render immediately in order, no waiting |

## Testing

`--selfcheck`, as the rest of the app does:

1. `BeatSplitter` on a full lesson: beats come out in emission order, prose is
   split into sentences, `DRAW:` lines are not in the spoken text.
2. **Chunk-boundary property:** feeding the same text split at every possible
   position yields byte-identical beats to feeding it whole. This is the bug this
   parser will otherwise have.
3. A malformed `DRAW:` line is dropped without dropping the beats around it.
4. `3.14` does not end a sentence; `end. Next` does.

The streaming client and the OpenAI call are integration — verified by running one
real Pythagoras lesson.

## Risks

The drawing system prompt was tuned over a full session against Gemini, and
GPT-5.6's accuracy on screen coordinates is unverified. The brain stays
switchable and Gemini remains available, but budget for re-tuning the geometry
guidance. If `gpt-5.6-luna` is weak at it, `gpt-5.6-terra` is a settings change.

## Deliberate cuts

RAG and any embedding index, the `DRAWINGS:` block format, an abbreviation-aware
sentence splitter, word-level draw anchoring (`willSpeakRangeOfSpeechString`
could fire a shape mid-sentence; sentence granularity is enough), resumable
streams, and OpenAI for anything but chat and lessons — agents stay on the CLI.

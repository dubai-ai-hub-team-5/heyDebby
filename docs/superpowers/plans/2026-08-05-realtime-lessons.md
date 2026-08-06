# Realtime Lessons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Debby draws each shape at the moment she talks about it, and starts talking in under a second instead of twelve.

**Architecture:** The model emits one marker per line (`DRAW:`, `POINT:`) inline between sentences instead of one JSON array at the end. A `BeatSplitter` turns that text — streamed in fragments or arriving whole — into an ordered list of `Beat`s. A `LessonPlayer` walks that list, speaking each sentence to completion before releasing whatever follows it. A new OpenAI Responses streaming backend feeds the splitter as tokens arrive.

**Tech Stack:** Swift 5.9+, macOS 14+, Foundation / AppKit / SwiftUI / AVFoundation only. No third-party packages.

## Global Constraints

- **Zero dependencies.** `Package.swift` has none and gains none. SSE parsing uses `URLSession.bytes(for:)`, which is Foundation.
- **Tests are `assert` calls inside `runSelfCheck()`** in `Sources/HeyDebby/main.swift`. There is no XCTest target. `assert` is compiled out of release builds, which is why `build.sh` runs the debug binary.
- **The verification command for every task is `./build.sh`.** It runs `swift build`, then `.build/debug/HeyDebby --selfcheck`, then the release build and codesign. A failed assert aborts the script.
- **Coordinates are normalized `[0,1]` fractions of the screenshot, top-left origin.** Unchanged by this work.
- **OpenAI endpoint:** `POST https://api.openai.com/v1/responses` with `"stream": true`.
- **OpenAI models:** `gpt-5.6-luna` (default), `gpt-5.6-terra`, `gpt-5.6-sol`.
- **SSE contract:** incremental text arrives as `data: {"type":"response.output_text.delta","delta":"…"}`. The stream ends with `response.completed`.
- **Every new file goes in `Sources/HeyDebby/`.** SwiftPM compiles the directory; there is no target list to update.

---

### Task 0: Version control baseline

This directory is not a git repository. Tasks 2 and 3 delete working parsing and rendering code, and without commits there is no way back. Skip only if you have another snapshot.

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
.build/
build/
.swiftpm/
```

- [ ] **Step 2: Initialise and commit the baseline**

```bash
git init && git add -A && git commit -m "chore: baseline before realtime lessons"
```

- [ ] **Step 3: Verify the tree is clean**

Run: `git status --porcelain`
Expected: no output.

---

### Task 1: `Beat` and `BeatSplitter`

The parser. Pure, no I/O, fully covered by selfcheck.

**Files:**
- Create: `Sources/HeyDebby/Beats.swift`
- Modify: `Sources/HeyDebby/Claude.swift` (add `Equatable` to `Annotation`, `ShapeSpec`, `ShapeSpec.Point`)
- Test: `Sources/HeyDebby/main.swift` (`runSelfCheck()`)

**Interfaces:**
- Consumes: `Annotation`, `ShapeSpec` from `Claude.swift`.
- Produces:
  - `enum Beat: Equatable { case say(String); case draw(ShapeSpec); case point(Annotation) }`
  - `struct BeatSplitter` with `mutating func feed(_ chunk: String) -> [Beat]`, `mutating func finish() -> [Beat]`, and `private(set) var more: Bool`.

- [ ] **Step 1: Make the payload types Equatable**

In `Sources/HeyDebby/Claude.swift`, change three declarations:

```swift
struct Annotation: Codable, Equatable {
```

```swift
struct ShapeSpec: Codable, Equatable {
    struct Point: Codable, Equatable { let x: Double; let y: Double }
```

Conformance is synthesised — all stored properties are `Double`, `String`, optionals of those, or arrays of `Point`. This exists so the chunk-boundary test in Step 2 can compare whole beat arrays.

- [ ] **Step 2: Write the failing tests**

Add to the top of `runSelfCheck()` in `Sources/HeyDebby/main.swift`, immediately after `func runSelfCheck() {`:

```swift
    // --- BeatSplitter ---
    let lesson = """
    The hypotenuse is the long side. It faces the right angle.
    DRAW: {"tool":"line","points":[{"x":0.3,"y":0.7},{"x":0.6,"y":0.4}],"color":"orange"}
    Now the square that stands on it.
    POINT: {"x":0.42,"y":0.18,"label":"File menu"}
    MORE: yes
    """
    func splitWhole(_ s: String) -> [Beat] {
        var sp = BeatSplitter()
        var b = sp.feed(s)
        b += sp.finish()
        return b
    }
    let lb = splitWhole(lesson)
    assert(lb.count == 5, "expected 4 sentences/markers + 1, got \(lb.count): \(lb)")
    assert(lb[0] == .say("The hypotenuse is the long side."), "sentence 1 wrong: \(lb[0])")
    assert(lb[1] == .say("It faces the right angle."), "sentence 2 wrong: \(lb[1])")
    if case .draw(let s) = lb[2] {
        assert(s.tool == "line" && s.points.count == 2 && abs(s.points[0].x - 0.3) < 1e-9,
               "DRAW line did not decode: \(s)")
    } else { assert(false, "beat 2 should be a draw, got \(lb[2])") }
    assert(lb[3] == .say("Now the square that stands on it."), "sentence 3 wrong: \(lb[3])")
    if case .point(let a) = lb[4] {
        assert(a.label == "File menu" && abs(a.x - 0.42) < 1e-9, "POINT did not decode: \(a)")
    } else { assert(false, "beat 4 should be a point, got \(lb[4])") }

    // MORE: is a flag, not a beat, and is never spoken.
    var moreSp = BeatSplitter()
    _ = moreSp.feed(lesson)
    _ = moreSp.finish()
    assert(moreSp.more, "MORE: yes must set the flag")
    assert(!splitWhole("All done — that's the theorem.").contains { $0 == .say("MORE: yes") },
           "the MORE marker must never be spoken")

    // The bug this parser would otherwise have: a chunk boundary anywhere must not
    // change the output. SSE deltas split mid-word and mid-marker.
    let chars = Array(lesson)
    for cut in 1..<chars.count {
        var sp = BeatSplitter()
        var b = sp.feed(String(chars[..<cut]))
        b += sp.feed(String(chars[cut...]))
        b += sp.finish()
        assert(b == lb, "split at \(cut) changed the beats:\n\(b)\nvs\n\(lb)")
    }

    // A decimal point is not a sentence end: no whitespace follows the dot.
    assert(splitWhole("Pi is 3.14 exactly.") == [.say("Pi is 3.14 exactly.")],
           "3.14 must not split: \(splitWhole("Pi is 3.14 exactly."))")

    // One malformed shape must not kill the lesson around it.
    let bad = splitWhole("First.\nDRAW: {not json}\nSecond.")
    assert(bad == [.say("First."), .say("Second.")], "a bad DRAW line must be dropped alone: \(bad)")

    // Models wrap things in fences and bullets; those lines carry no content.
    let fenced = splitWhole("Look.\n```json\nDRAW: {\"tool\":\"circle\",\"points\":[{\"x\":0.1,\"y\":0.1},{\"x\":0.2,\"y\":0.2}]}\n```\nDone.")
    assert(fenced.count == 3, "fences must be ignored, not spoken: \(fenced)")
```

- [ ] **Step 3: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error, `cannot find 'BeatSplitter' in scope`. In Swift a missing type is a build failure, not a failing assertion — that is the red state here.

- [ ] **Step 4: Write the implementation**

Create `Sources/HeyDebby/Beats.swift`:

```swift
import Foundation

/// One unit of a lesson, in the order the model emitted it.
enum Beat: Equatable {
    case say(String)
    case draw(ShapeSpec)
    case point(Annotation)
}

/// Splits a model reply — streamed in fragments or handed over whole — into ordered beats.
///
/// One marker per line, unlike the `DRAWINGS: [ … ]` block this replaces. A line is the
/// smallest thing a stream lets you be sure is complete; a JSON array is only complete at
/// its closing bracket, which arrives after every shape it contains.
struct BeatSplitter {
    private(set) var more = false

    private var line = ""    // characters since the last newline, still possibly a marker
    private var prose = ""   // prose accumulating toward a sentence end

    private static let markers = ["DRAW:", "POINT:", "MORE:"]

    /// True while the buffer is still growing toward a marker, or has already become
    /// one. Both halves are needed: the first holds "DRA" until it can be ruled out,
    /// the second keeps holding once "DRAW:" is complete and its JSON is arriving —
    /// without it the space after the colon ends the prefix match and the whole
    /// marker line gets spoken as prose.
    ///
    /// Once neither holds, the characters are prose and can be released without
    /// waiting for the newline — which is what lets speech start on the first
    /// sentence rather than the first line.
    private static func couldBeMarker(_ s: String) -> Bool {
        let u = s.uppercased()
        return markers.contains { $0.hasPrefix(u) || u.hasPrefix($0) }
    }

    mutating func feed(_ chunk: String) -> [Beat] {
        var out: [Beat] = []
        for ch in chunk {
            if ch == "\n" {
                out += flushLine()
            } else {
                line.append(ch)
                if !Self.couldBeMarker(line) {
                    prose += line
                    line = ""
                    out += releaseSentences()
                }
            }
        }
        return out
    }

    /// End of stream: the last line has no newline and the last sentence may have no
    /// terminator. Both still have to be said.
    mutating func finish() -> [Beat] {
        var out = flushLine()
        out += flushProse()
        return out
    }

    private mutating func flushLine() -> [Beat] {
        let raw = line.trimmingCharacters(in: .whitespaces)
        line = ""
        let l = Self.normalize(raw)
        if l.isEmpty { return prose.isEmpty ? [] : releaseSentences() }

        if let json = Self.payload(l, "DRAW:") {
            var out = flushProse()   // the sentence before a marker is finished by it
            if let s = try? JSONDecoder().decode(ShapeSpec.self, from: Data(json.utf8)) {
                out.append(.draw(s))
            }
            return out
        }
        if let json = Self.payload(l, "POINT:") {
            var out = flushProse()
            if let a = try? JSONDecoder().decode(Annotation.self, from: Data(json.utf8)) {
                out.append(.point(a))
            }
            return out
        }
        if let rest = Self.payload(l, "MORE:") {
            more = rest.lowercased().contains("yes")
            return []
        }
        // Prose. A newline ends a sentence even without punctuation.
        prose += l + " "
        return releaseSentences()
    }

    /// Strips what models decorate lines with. A fence line carries no content at all.
    private static func normalize(_ s: String) -> String {
        if s.hasPrefix("```") { return "" }
        var t = s
        for junk in ["**", "- ", "* "] where t.hasPrefix(junk) {
            t = String(t.dropFirst(junk.count))
        }
        if t.hasSuffix("**") { t = String(t.dropLast(2)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func payload(_ line: String, _ marker: String) -> String? {
        guard line.uppercased().hasPrefix(marker) else { return nil }
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Emits every complete sentence in `prose`. A sentence ends at `.`, `!` or `?`
    /// followed by whitespace that has actually arrived — so `3.14` stays whole, and a
    /// final sentence with nothing after it waits for `finish()`.
    private mutating func releaseSentences() -> [Beat] {
        var out: [Beat] = []
        while let end = Self.sentenceEnd(in: prose) {
            let s = String(prose[..<end]).trimmingCharacters(in: .whitespaces)
            prose = String(prose[end...])
            if !s.isEmpty { out.append(.say(s)) }
        }
        return out
    }

    private static func sentenceEnd(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if ".!?".contains(s[i]) {
                let next = s.index(after: i)
                if next < s.endIndex, s[next].isWhitespace { return next }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private mutating func flushProse() -> [Beat] {
        var out = releaseSentences()
        let rest = prose.trimmingCharacters(in: .whitespaces)
        prose = ""
        if !rest.isEmpty { out.append(.say(rest)) }
        return out
    }
}
```

- [ ] **Step 5: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 6: Commit**

```bash
git add Sources/HeyDebby/Beats.swift Sources/HeyDebby/Claude.swift Sources/HeyDebby/main.swift
git commit -m "feat: BeatSplitter — one marker per line, streaming-safe"
```

---

### Task 2: `parseReply` on top of `BeatSplitter`

Switch the wire format without touching rendering. `annotations` and `drawings` become computed views over the beats, so every existing call site keeps compiling and behaving exactly as it does now. Task 3 removes them.

**Files:**
- Modify: `Sources/HeyDebby/Claude.swift` — replace `extractBlock` and `parseReply`; rewrite the marker docs in `basePrompt`
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Consumes: `BeatSplitter`, `Beat` from Task 1.
- Produces: `struct ParsedReply { var beats: [Beat]; var text: String; var more: Bool }` plus computed `annotations: [Annotation]` and `drawings: [ShapeSpec]`.

- [ ] **Step 1: Rewrite the existing marker tests for the new format**

In `runSelfCheck()`, the assertions at roughly lines 5–34 and 70–72 and 100–103 use `ANNOTATIONS:` / `DRAWINGS:` blocks. Replace that whole set with:

```swift
    let r1 = parseReply("Click the File menu.\nPOINT: {\"x\":0.1,\"y\":0.2,\"label\":\"File\"}")
    assert(r1.text == "Click the File menu.", "clean text wrong: \(r1.text)")
    assert(r1.annotations.count == 1 && r1.annotations[0].label == "File"
           && abs(r1.annotations[0].x - 0.1) < 0.0001, "annotation parse wrong")
    let r2 = parseReply("No pointing needed.")
    assert(r2.text == "No pointing needed." && r2.annotations.isEmpty)
    let r3 = parseReply("Look here.\nPOINT: not json")
    assert(r3.annotations.isEmpty, "bad json should yield no annotations")
    assert(r3.text == "Look here.", "a bad marker line must not be spoken: \(r3.text)")

    let rA = parseReply("Here.\nPOINT: {\"x\":0.1,\"y\":0.2,\"w\":0.3,\"h\":0.15,\"label\":\"Toolbar\"}")
    assert(rA.annotations.count == 1 && rA.annotations[0].w == 0.3 && rA.annotations[0].h == 0.15,
           "area annotation parse wrong")

    let rM = parseReply("""
    Here's the triangle.
    DRAW: {"tool":"triangle","points":[{"x":0.2,"y":0.7},{"x":0.5,"y":0.7},{"x":0.2,"y":0.4}]}
    DRAW: {"tool":"text","points":[{"x":0.27,"y":0.52}],"label":"a"}
    """)
    assert(rM.drawings.count == 2, "two DRAW lines must parse: \(rM.drawings.count)")
    assert(rM.drawings[0].points.count == 3, "3-vertex triangle must survive")
    assert(rM.drawings[1].label == "a", "text label must survive")
    assert(rM.text == "Here's the triangle.", "markers must leave the spoken text: \(rM.text)")

    let rB = parseReply("Look.\nDRAW: {\"tool\":\"text\",\"points\":[{\"x\":0.1,\"y\":0.1}],\"label\":\"c] \"}")
    assert(rB.drawings.count == 1 && rB.drawings[0].label == "c] ",
           "brackets inside a label must not confuse the parser")

    let step = parseReply("Now side b.\nDRAW: {\"tool\":\"line\",\"points\":[{\"x\":0.2,\"y\":0.7},{\"x\":0.5,\"y\":0.7}]}\nMORE: yes")
    assert(step.more && step.drawings.count == 1, "MORE: yes must mean another step is queued")
    assert(step.text == "Now side b.", "the MORE marker must not be spoken: \(step.text)")
    assert(!parseReply("All done — that's the theorem.").more, "no marker means the lesson ended")
```

Leave every other assertion in `runSelfCheck()` untouched — the `DrawnShape` geometry, `agentCommand`, `mapToScreen`, `isTalkChord` and `resolveBackend` blocks are unaffected.

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: assertion failure — `parseReply` still expects block markers, so `POINT:`/`DRAW:` lines land in the spoken text and `r1.text` is wrong.

- [ ] **Step 3: Replace `ParsedReply` and `parseReply`, delete `extractBlock`**

In `Sources/HeyDebby/Claude.swift`, delete the entire `private func extractBlock(...)` function (currently lines 41–73) and replace the `ParsedReply` struct and `parseReply` function (currently lines 75–112) with:

```swift
/// A model reply split into its parts. A struct, not a tuple: this has grown twice and each
/// time every `let (a, b) =` call site broke at compile time for no good reason.
struct ParsedReply {
    var beats: [Beat] = []
    var text = ""      // what gets shown in the notch: every spoken sentence, joined
    var more = false   // the model says this lesson has another step
}

extension ParsedReply {
    /// Views over the beats, for callers that only want one kind. Order within each
    /// kind is preserved; the interleaving is in `beats`.
    var annotations: [Annotation] {
        beats.compactMap { if case .point(let a) = $0 { return a } else { return nil } }
    }
    var drawings: [ShapeSpec] {
        beats.compactMap { if case .draw(let s) = $0 { return s } else { return nil } }
    }
}

/// Splits a whole (non-streamed) reply. A complete reply is just a stream that arrived at
/// once, so it goes through the same splitter — one format, one parser.
func parseReply(_ text: String) -> ParsedReply {
    var sp = BeatSplitter()
    var out = ParsedReply()
    out.beats = sp.feed(text) + sp.finish()
    out.more = sp.more
    out.text = out.beats
        .compactMap { if case .say(let s) = $0 { return s } else { return nil } }
        .joined(separator: " ")
    return out
}
```

- [ ] **Step 4: Rewrite the marker documentation in the system prompt**

In `Sources/HeyDebby/Claude.swift`, inside `basePrompt`, replace the `ANNOTATIONS:` paragraph (currently lines 153–157) and the `DRAWINGS:` paragraph (currently lines 159–174) with:

```
    To point at a spot or mark a whole area, put a line of its own:
    POINT: {"x":0.42,"y":0.18,"label":"File menu"}
    An entry with only x,y points at a single spot. An entry with w,h marks a whole area whose \
    top-left corner is (x,y). All values are fractions of the screenshot's width/height, top-left origin. \
    Use an area for regions; use a point when the user should click. Omit when nothing to mark.

    You CAN draw on the user's screen — shapes AND text — and you do it yourself. NEVER say you \
    cannot draw, never say "picture this" or "imagine", and never ask the user to draw. If a visual \
    helps, draw it. Each shape is one line of its own:
    DRAW: {"tool":"line","points":[{"x":0.3,"y":0.7},{"x":0.3,"y":0.35}],"color":"orange","lineWidth":4}
    DRAW: {"tool":"text","points":[{"x":0.27,"y":0.52}],"label":"a","color":"orange"}

    PUT EACH DRAW LINE DIRECTLY AFTER THE SENTENCE THAT DESCRIBES IT. Your words and your \
    drawing are played back in the order you write them: the sentence is spoken, then the shape \
    appears, then the next sentence. Never collect the shapes at the end — that draws the whole \
    picture before you have said anything about it. One shape per line, never an array, never \
    inside ``` fences.

    Tools: line, arrow, triangle, polygon, square, rectangle, circle, curve, text.
    - text writes label at its single point — use it for every side name, length, angle and formula.
    - triangle takes 3 points for real vertices (use this for right triangles), or 2 for a \
    bounding box. rectangle/circle take 2. line/arrow take start+end. curve takes many.
    - square takes the two endpoints of a side and stands a true square on it — this is the ONLY \
    correct way to draw the square on a leg or hypotenuse. Never use rectangle for that: rectangle \
    is always upright, and a square on a slanted side is not. It must touch the side it belongs to, \
    never float in empty space.
    - polygon closes a shape through ALL its points — for any other shape that isn't axis-aligned.
    Points are [0,1] fractions of the screenshot's width/height, top-left origin — same space as \
    POINT, and both can appear in one reply. Colors: orange, white, red, blue, green, yellow. \
    lineWidth defaults to 3.
```

Then, in the "Everything you have already drawn is STILL ON SCREEN" paragraph (currently lines 182–187), change `Your earlier DRAWINGS lines` to `Your earlier DRAW lines`.

- [ ] **Step 5: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 6: Commit**

```bash
git add Sources/HeyDebby/Claude.swift Sources/HeyDebby/main.swift
git commit -m "feat: DRAW:/POINT: line markers replace the DRAWINGS:/ANNOTATIONS: blocks"
```

---

### Task 3: `LessonPlayer` — speech-paced playback

The feature itself, and the deletion of three timing guesses.

**Files:**
- Create: `Sources/HeyDebby/Lesson.swift`
- Modify: `Sources/HeyDebby/AppState.swift:390-481` (the render-and-advance block inside `talk`)
- Test: `Sources/HeyDebby/main.swift`

The `annotations` / `drawings` extension in `Claude.swift` stays — the Task 2 selfcheck assertions read through it, and it is four lines.

**Interfaces:**
- Consumes: `Beat` (Task 1), `ParsedReply.beats` (Task 2).
- Produces: `final class LessonPlayer` with `var onSay: ((String) -> Void)?`, `var onDraw: ((ShapeSpec) -> Void)?`, `var onPoint: ((Annotation) -> Void)?`, `var onIdle: (() -> Void)?`, and methods `append(_ beats: [Beat])`, `closeStream()`, `speechFinished()`, `cancel()`.

- [ ] **Step 1: Write the failing test**

Add to `runSelfCheck()` in `Sources/HeyDebby/main.swift`, after the BeatSplitter block:

```swift
    // --- LessonPlayer: a shape waits for the sentence in front of it ---
    let lp = LessonPlayer()
    var played: [String] = []
    lp.onSay = { played.append("say:\($0)") }
    lp.onDraw = { played.append("draw:\($0.tool)") }
    lp.onPoint = { played.append("point:\($0.label)") }
    var idle = false
    lp.onIdle = { idle = true }

    let lineShape = ShapeSpec(tool: "line", points: [.init(x: 0, y: 0), .init(x: 1, y: 1)],
                              color: nil, lineWidth: nil, label: nil)
    lp.append([.say("one"), .draw(lineShape), .say("two")])
    assert(played == ["say:one"],
           "nothing may play while a sentence is still being spoken: \(played)")
    lp.speechFinished()
    assert(played == ["say:one", "draw:line", "say:two"],
           "the shape must land between its two sentences: \(played)")
    assert(!idle, "still speaking — not idle yet")
    lp.speechFinished()
    lp.closeStream()
    assert(idle, "queue drained and stream closed means idle")

    // Beats arriving after playback has started still queue behind the current sentence.
    let lp2 = LessonPlayer()
    var played2: [String] = []
    lp2.onSay = { played2.append("say:\($0)") }
    lp2.onDraw = { played2.append("draw:\($0.tool)") }
    lp2.append([.say("first")])
    lp2.append([.draw(lineShape)])
    assert(played2 == ["say:first"], "a late-arriving shape must still wait: \(played2)")
    lp2.speechFinished()
    assert(played2 == ["say:first", "draw:line"], "…and play once the sentence ends: \(played2)")

    // With speech off there is nothing to wait for.
    let lp3 = LessonPlayer(speechEnabled: false)
    var played3: [String] = []
    lp3.onSay = { played3.append("say:\($0)") }
    lp3.onDraw = { played3.append("draw:\($0.tool)") }
    lp3.append([.say("a"), .draw(lineShape), .say("b")])
    assert(played3 == ["say:a", "draw:line", "say:b"],
           "voiceReplies off must not stall the queue: \(played3)")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error, `cannot find 'LessonPlayer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HeyDebby/Lesson.swift`:

```swift
import Foundation

/// Plays beats in order, holding everything behind the sentence currently being spoken.
///
/// That wait is the whole point. Streamed text outruns speech by an order of magnitude, so
/// without it every shape in a lesson lands within the first two seconds while Debby is still
/// reading sentence one — which is the behaviour this replaces.
///
/// Main-thread only: `AppState` owns it and drives it from the speech delegate.
final class LessonPlayer {
    var onSay: ((String) -> Void)?
    var onDraw: ((ShapeSpec) -> Void)?
    var onPoint: ((Annotation) -> Void)?
    /// Queue drained and no more beats coming — where auto-advance hangs off.
    var onIdle: (() -> Void)?

    private let speechEnabled: Bool
    private var queue: [Beat] = []
    private var speaking = false
    private var streamOpen = true

    /// With `voiceReplies` off nothing ever reports back, so nothing may wait.
    init(speechEnabled: Bool = true) {
        self.speechEnabled = speechEnabled
    }

    func append(_ beats: [Beat]) {
        queue += beats
        pump()
    }

    /// The model has finished; once the queue drains, the lesson is over.
    func closeStream() {
        streamOpen = false
        pump()
    }

    /// Called when the synthesiser finishes or cancels an utterance.
    func speechFinished() {
        speaking = false
        pump()
    }

    func cancel() {
        queue.removeAll()
        speaking = false
        streamOpen = false
    }

    private func pump() {
        while !speaking, !queue.isEmpty {
            switch queue.removeFirst() {
            case .draw(let s):  onDraw?(s)
            case .point(let a): onPoint?(a)
            case .say(let t):
                if speechEnabled { speaking = true }
                onSay?(t)
            }
        }
        if !speaking, queue.isEmpty, !streamOpen { onIdle?() }
    }
}
```

- [ ] **Step 4: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 5: Commit the player before rewiring**

```bash
git add Sources/HeyDebby/Lesson.swift Sources/HeyDebby/main.swift
git commit -m "feat: LessonPlayer — sentences gate what follows them"
```

- [ ] **Step 6: Rewire `AppState` onto the player**

In `Sources/HeyDebby/AppState.swift`, replace everything from `show(clean)` (line 390) through the end of the `else if parsed.more { … }` block (line 481) with the code below. The lines being deleted are the `33 chars/sec` annotation timing, the `Double(i) * 0.5` per-shape reveal delay, and the `Double(clean.count) / 33.0` auto-advance delay — all three are guesses that the player replaces with the real end-of-speech signal.

```swift
                show(clean)
                let player = LessonPlayer(speechEnabled: voiceReplies)
                lessonPlayer = player
                if !parsed.annotations.isEmpty { overlay.showEmpty(on: screen) }
                attach(player, gen: gen, container: snapContainer, screen: screen,
                       more: { parsed.more })
                player.append(parsed.beats)
                player.closeStream()
```

The wiring itself goes in its own method, because Task 5's streaming path needs exactly the same four closures — the only difference between a streamed and a whole reply is when the beats arrive. Add to `AppState.swift`:

```swift
    /// Wires a player to the screen and the voice. `more` is a closure rather than a Bool
    /// because a streamed reply only knows whether the lesson continues once the stream
    /// has closed — which is before `onIdle` fires, but after this is called.
    private func attach(_ player: LessonPlayer, gen: Int, container: CGRect?,
                        screen: NSScreen, more: @escaping () -> Bool) {
        player.onSay = { [weak self] sentence in
            guard let self, self.chatGeneration == gen else { return }
            if self.voiceReplies { self.voice.speak(sentence) }
        }
        player.onPoint = { [weak self] ann in
            guard let self, self.chatGeneration == gen else { return }
            let m = mapToScreen(ann, container: container)
            let f = screen.frame
            let cx = m.x + (m.w ?? 0) / 2, cy = m.y + (m.h ?? 0) / 2
            self.pointer.highlight([CGPoint(x: f.minX + cx * f.width,
                                            y: f.minY + (1 - cy) * f.height)])
            self.overlay.addAnnotation(m)
            self.showNext = true
            self.armClickWatch()
        }
        player.onDraw = { [weak self] spec in
            guard let self, self.chatGeneration == gen,
                  let shape = self.drawnShape(from: spec, container: container,
                                              screen: screen) else { return }
            self.drawingController.shapes.append(shape)
        }
        // The lesson advances when the narration actually ends, not on a timer.
        player.onIdle = { [weak self] in
            guard let self, self.chatGeneration == gen, more() else { return }
            guard self.autoSteps < self.maxAutoSteps else {
                DebbyLog.write("AUTO-STEP cap (\(self.maxAutoSteps)) hit — stopping the lesson")
                return
            }
            self.autoSteps += 1
            self.pendingAdvance = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
                guard let self, self.chatGeneration == gen, !self.isListening else { return }
                self.submit("continue", auto: true)
            }
        }
    }
```

- [ ] **Step 7: Add the player property and the speech hook**

In `AppState.swift`, beside `private var runningAgents: [Process] = []` (line 74), add:

```swift
    private var lessonPlayer: LessonPlayer?
```

Find where `voice.onSpeakEnd` is assigned (near line 94, the closure that clears `speakingText`) and add the player hand-off as the last statement inside that closure:

```swift
                self?.lessonPlayer?.speechFinished()
```

In `submit(_:auto:)`, immediately after `voice.stop()` (line 327), add:

```swift
        lessonPlayer?.cancel()
        lessonPlayer = nil
```

- [ ] **Step 8: Extract the ShapeSpec → DrawnShape conversion**

The deleted block contained the `ShapeSpec` → `DrawnShape` mapping inline. Add it to `AppState.swift` as a method, using exactly the conversion that was there:

```swift
    /// Normalized ShapeSpec → on-screen DrawnShape. A text label is one point;
    /// everything else needs a start and an end.
    private func drawnShape(from spec: ShapeSpec, container: CGRect?,
                            screen: NSScreen) -> DrawnShape? {
        guard let tool = DrawTool(rawValue: spec.tool) else { return nil }
        guard spec.points.count >= (tool == .text ? 1 : 2) else { return nil }
        let pts = spec.points.map { pt -> CGPoint in
            let m = mapToScreen(Annotation(x: pt.x, y: pt.y, label: ""), container: container)
            return CGPoint(x: m.x * screen.frame.width, y: m.y * screen.frame.height)
        }
        return DrawnShape(tool: tool, points: pts,
                          color: DrawnShape.color(named: spec.color) ?? .orange,
                          lineWidth: CGFloat(spec.lineWidth ?? 3), label: spec.label)
    }
```

If the original inline code built `DrawnShape` differently — a different colour lookup or a different default — copy that version verbatim rather than this one. Read lines 430–463 of the pre-edit file (`git show HEAD~1:Sources/HeyDebby/AppState.swift`) to confirm.

- [ ] **Step 9: Delete the compatibility accessors**

Nothing outside `parseReply`'s own tests uses `parsed.annotations` or `parsed.drawings` now except the two `!parsed.annotations.isEmpty` checks above. Keep the extension in `Claude.swift` — the selfcheck assertions in Task 2 read through it, and it is four lines. Remove the `DebbyLog.write("PARSED …")` line's references only if they no longer compile.

- [ ] **Step 10: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 11: Verify by hand**

Run: `open build/HeyDebby.app`, hold ⌃⌥ and say "explain the Pythagorean theorem".
Expected: each shape appears after the sentence describing it, not all at once, and the next step starts without saying "continue".

- [ ] **Step 12: Commit**

```bash
git add Sources/HeyDebby/AppState.swift Sources/HeyDebby/main.swift
git commit -m "feat: speech-paced drawing; delete the 33 chars/sec timing guesses"
```

---

### Task 4: OpenAI Responses streaming client

**Files:**
- Create: `Sources/HeyDebby/OpenAI.swift`
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Consumes: `Claude.systemPrompt`.
- Produces: `enum OpenAI` with `static let defaultModel = "gpt-5.6-luna"`, `static func delta(fromSSELine:) -> String?`, and `static func stream(apiKey:model:history:userText:imageB64:onDelta:) async throws`.

- [ ] **Step 1: Write the failing test**

Add to `runSelfCheck()`:

```swift
    // --- OpenAI SSE frames ---
    assert(OpenAI.delta(fromSSELine:
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hy\",\"sequence_number\":1}") == "Hy",
        "output_text.delta must yield its text")
    assert(OpenAI.delta(fromSSELine:
        "data: {\"type\":\"response.created\",\"sequence_number\":0}") == nil,
        "non-text events carry no delta")
    assert(OpenAI.delta(fromSSELine: "data: [DONE]") == nil, "the DONE sentinel is not text")
    assert(OpenAI.delta(fromSSELine: "") == nil, "SSE keep-alive blank lines are not text")
    assert(OpenAI.delta(fromSSELine: "event: response.output_text.delta") == nil,
           "only data: lines carry payloads")
    assert(OpenAI.defaultModel == "gpt-5.6-luna", "default model changed without a decision")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: compile error, `cannot find 'OpenAI' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/HeyDebby/OpenAI.swift`:

```swift
import Foundation

enum OpenAI {
    /// The fast, cheap member of the GPT-5.6 family. A lesson is a dozen turns, so this
    /// is the one that matters; gpt-5.6-terra and gpt-5.6-sol are settings away.
    static let defaultModel = "gpt-5.6-luna"

    /// One SSE line → the text it carries, or nil. Everything that isn't an output-text
    /// delta is noise here: lifecycle events, keep-alive blank lines, the [DONE] sentinel.
    static func delta(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let json = String(line.dropFirst(6))
        guard json != "[DONE]",
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              obj["type"] as? String == "response.output_text.delta" else { return nil }
        return obj["delta"] as? String
    }

    /// Streams a reply, handing each text fragment to `onDelta` as it arrives.
    /// Returns when the stream closes; throws on a non-200 or a transport failure.
    static func stream(apiKey: String, model: String,
                       history: [(role: String, text: String)],
                       userText: String, imageB64: String,
                       onDelta: @escaping (String) -> Void) async throws {
        var input: [[String: Any]] = history.suffix(6).map { h in
            // Assistant turns are output_text; user turns are input_text. Mixing them up
            // is a 400 that reads like a malformed request rather than a role problem.
            let type = h.role == "assistant" ? "output_text" : "input_text"
            return ["role": h.role, "content": [["type": type, "text": h.text]]]
        }
        var content: [[String: Any]] = [["type": "input_text", "text": userText]]
        if !imageB64.isEmpty {
            content.insert(["type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(imageB64)"], at: 0)
        }
        input.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": model.isEmpty ? defaultModel : model,
            "instructions": Claude.systemPrompt,
            "input": input,
            "stream": true,
        ]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            // The error body arrives down the same byte stream; without draining it the
            // failure is a bare status code and undiagnosable.
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw openAIErr("OpenAI API error \(status): \(detail.isEmpty ? "no body" : detail)")
        }
        for try await line in bytes.lines {
            if let d = delta(fromSSELine: line) { onDelta(d) }
        }
    }
}

func openAIErr(_ msg: String) -> NSError {
    NSError(domain: "openai", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}
```

- [ ] **Step 4: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 5: Commit**

```bash
git add Sources/HeyDebby/OpenAI.swift Sources/HeyDebby/main.swift
git commit -m "feat: OpenAI Responses streaming client"
```

---

### Task 5: Wire the OpenAI brain in

**Files:**
- Modify: `Sources/HeyDebby/AppState.swift:24` (`resolveBackend`), `:126-135` (key/model accessors), `:339-374` (`talk`)
- Modify: `Sources/HeyDebby/UI.swift:776-830` (settings)
- Test: `Sources/HeyDebby/main.swift`

**Interfaces:**
- Consumes: `OpenAI.stream`, `LessonPlayer`, `BeatSplitter`.
- Produces: backend id `"openai"`; `UserDefaults` keys `openaiApiKey`, `openaiModel`.

- [ ] **Step 1: Write the failing test**

Add to `runSelfCheck()`, beside the existing `resolveBackend` assertions:

```swift
    assert(resolveBackend("openai", codex: true, claudeCLI: true) == "openai",
           "an explicitly chosen brain must win over auto-detection")
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `./build.sh`
Expected: assertion failure — `resolveBackend` falls through to `"codex"`.

- [ ] **Step 3: Accept the backend id**

In `AppState.swift` line 24, add `"openai"` to the list:

```swift
    if ["codex", "claude", "claudecli", "gemini", "openai"].contains(stored) { return stored }
```

- [ ] **Step 4: Add the key and model accessors**

In `AppState.swift`, beside the `geminiApiKey` / `geminiModel` computed properties (lines 126–135), add:

```swift
    var openaiApiKey: String {
        let stored = UserDefaults.standard.string(forKey: "openaiApiKey") ?? ""
        return stored.isEmpty ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "") : stored
    }
    var openaiModel: String {
        let m = UserDefaults.standard.string(forKey: "openaiModel") ?? ""
        return m.isEmpty ? OpenAI.defaultModel : m
    }
```

If the `geminiApiKey` accessor reads its environment fallback differently, match that shape instead — consistency inside the file beats consistency with this plan.

- [ ] **Step 5: Add the missing-key guard**

In `talk(_:)`, after the `gemini` guard (line 347), add:

```swift
        if backend == "openai" && openaiApiKey.isEmpty {
            show("I need an OpenAI API key — open ⚙︎ in the notch and paste one (or set OPENAI_API_KEY).")
            return
        }
```

- [ ] **Step 6: Stream into the player**

`talk` currently awaits one `reply` string and then parses it. OpenAI produces beats as it goes, so the switch gains a branch that plays while it streams and still ends with the same `reply` text for history. Replace the `let reply: String` / `switch backend { … }` block (lines 360–374) with:

```swift
                var reply = ""
                switch backend {
                case "codex":
                    reply = try await Codex.send(model: codexModel, history: history,
                                                 userText: text, imageB64: shot.base64)
                case "claudecli":
                    reply = try await Claude.CLI.send(history: history, userText: text,
                                                      imagePath: shot.filePath)
                case "gemini":
                    reply = try await Gemini.send(apiKey: geminiApiKey, model: geminiModel,
                                                   history: history, userText: text, imageB64: shot.base64)
                case "openai":
                    // Streamed: beats reach the player as they arrive, so Debby starts
                    // speaking at the first finished sentence instead of the last token.
                    reply = try await streamLesson(gen: gen, container: snapContainer,
                                                   screen: screen, text: text,
                                                   imageB64: shot.base64)
                default:
                    reply = try await Claude.send(apiKey: apiKey, model: model, history: history,
                                                  userText: text, imageB64: shot.base64)
                }
```

`streamLesson` reuses `attach` exactly as written in Task 3 — the closures are identical, only the arrival of the beats differs. Its `more()` reads the splitter, which is final by the time `onIdle` fires because `closeStream()` runs after `finish()`. Add to `AppState.swift`:

```swift
    /// Streams a reply straight into a player, returning the raw text for history.
    /// The splitter is a local `var` captured by the delta closure — legal, and simpler
    /// than threading it back out through an `inout` parameter.
    private func streamLesson(gen: Int, container: CGRect?, screen: NSScreen,
                              text: String, imageB64: String) async throws -> String {
        let player = LessonPlayer(speechEnabled: voiceReplies)
        lessonPlayer = player
        var sp = BeatSplitter()
        attach(player, gen: gen, container: container, screen: screen, more: { sp.more })

        var raw = ""
        try await OpenAI.stream(apiKey: openaiApiKey, model: openaiModel, history: history,
                                userText: text, imageB64: imageB64) { chunk in
            raw += chunk
            let beats = sp.feed(chunk)
            if !beats.isEmpty {
                // The delta callback lands on a URLSession queue; the player is main-only.
                Task { @MainActor in player.append(beats) }
            }
        }
        let tail = sp.finish()
        await MainActor.run {
            if !tail.isEmpty { player.append(tail) }
            player.closeStream()
        }
        return raw
    }
```

The notch shows the answer as it is spoken, not before it, so the streamed path has no `show(clean)` to make. If you want the text to appear anyway, `show` from inside `onSay`.

Then, in the non-streaming path, guard the Task 3 playback so it does not run twice:

```swift
                if backend != "openai" {
                    let parsed = parseReply(reply)
                    …existing Task 3 playback…
                }
```

Keep `history.append((role: "assistant", text: reply))` outside that guard — the raw text with its `DRAW:` lines is the only record of what was drawn, and the next turn needs those coordinates.

- [ ] **Step 7: Add the settings UI**

In `UI.swift`, add the storage beside `geminiApiKey` (line 780):

```swift
    @AppStorage("openaiApiKey") private var openaiApiKey = ""
    @AppStorage("openaiModel") private var openaiModel = ""
```

Add a tag to the Brain picker after the Gemini entry (line 809):

```swift
                Text("OpenAI (GPT-5.6)").tag("openai")
```

Add a branch after the `gemini` branch (line 822):

```swift
            } else if resolveBackend(backend) == "openai" {
                SecureField("OpenAI API key (sk-…)", text: $openaiApiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Model (blank = \(OpenAI.defaultModel))", text: $openaiModel)
                    .textFieldStyle(.roundedBorder)
                Text("Streams, so Debby starts talking in about a second and draws each shape "
                     + "as she describes it. Blank key falls back to OPENAI_API_KEY. "
                     + "gpt-5.6-terra and gpt-5.6-sol are stronger and slower.")
                    .font(.caption).foregroundStyle(.secondary)
```

Match the exact modifiers used by the Gemini branch — copy its `.textFieldStyle` and caption styling rather than this approximation if they differ.

- [ ] **Step 8: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 9: Verify by hand**

Run: `open build/HeyDebby.app`, set ⚙︎ → Brain → OpenAI, paste a key, then ask "explain the Pythagorean theorem".
Expected: speech begins in about a second; shapes appear one per sentence. Check `~/Library/Logs/HeyDebby/debby.log` for `CHAT openai reply:` containing `DRAW:` lines.

- [ ] **Step 10: Commit**

```bash
git add Sources/HeyDebby/AppState.swift Sources/HeyDebby/UI.swift Sources/HeyDebby/main.swift
git commit -m "feat: OpenAI streaming brain wired to the lesson player"
```

---

### Task 6: Skip the screenshot on auto-advance turns

A lesson's later steps re-screenshot a screen whose only change is Debby's own drawing — which the screenshot excludes anyway. The capture, the upload and the image tokens are all wasted.

**Files:**
- Modify: `Sources/HeyDebby/AppState.swift:325-337` (`submit`), `:339-360` (`talk`)

**Interfaces:**
- Produces: `talk(_ text: String, withShot: Bool = true)`.

- [ ] **Step 1: Thread the flag through**

Change the signature:

```swift
    private func talk(_ text: String, withShot: Bool = true) {
```

and the call in `submit`:

```swift
        if let task = agentTask(from: text) {
            runAgent(task)
        } else {
            talk(text, withShot: !auto)
        }
```

- [ ] **Step 2: Skip the capture**

Replace the capture line (line 358) with:

```swift
                // An auto-advance step changes nothing on screen except our own drawing,
                // and the screenshot excludes our windows — so there is nothing new to see.
                let shot = withShot
                    ? try await Capture.screen(excludingSelf: true, cropTo: snapContainer,
                                               displayID: screen.displayID)
                    : Capture.Shot(base64: "", filePath: "")
```

If `Capture.Shot` has different member names or is not directly constructible, add a static `Capture.Shot.none` beside its definition in `Capture.swift` rather than changing call sites.

Every backend already tolerates an empty image: `Gemini.send` omits `inlineData` when `imageB64` is empty (a documented 400 otherwise), `OpenAI.stream` omits `input_image`, and `Claude.CLI.send` takes a path it simply will not read. Confirm the Codex and Claude API paths do the same before shipping; if one sends an empty image field, guard it the way Gemini does.

- [ ] **Step 3: Run the build to verify it passes**

Run: `./build.sh`
Expected: `Built build/HeyDebby.app`, no assertion output.

- [ ] **Step 4: Verify by hand**

Run a multi-step lesson and watch `~/Library/Logs/HeyDebby/debby.log`.
Expected: the first turn logs a capture; the auto-advance turns do not, and the lesson still draws each step in the right place relative to the last.

- [ ] **Step 5: Commit**

```bash
git add Sources/HeyDebby/AppState.swift Sources/HeyDebby/Capture.swift
git commit -m "perf: no screenshot on auto-advance steps"
```

---

## Notes for the implementer

- **The prompt will need tuning.** The drawing guidance was tuned over a full session against Gemini and the `DRAW:`-per-line format is new to it. If shapes come back in the wrong place or the model reverts to collecting them at the end, strengthen the "PUT EACH DRAW LINE DIRECTLY AFTER THE SENTENCE" paragraph before changing any parsing code.
- **`gpt-5.6-luna` may be weak at screen geometry.** It is a settings field; `gpt-5.6-terra` is one edit away. Judge it on whether squares stand on slanted sides correctly.
- **If a lesson goes silent**, check `debby.log` for the raw reply first. A reply with no `DRAW:` lines is a prompt problem; a reply with them that draws nothing is a splitter problem, and the chunk-boundary test in Task 1 is where to add the failing case.

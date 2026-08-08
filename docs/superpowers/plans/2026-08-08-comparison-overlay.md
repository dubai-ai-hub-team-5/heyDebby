# Live Comparison Overlay Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. Implement task-by-task, test-first, and verify each task with `./build.sh` before moving on.

**Goal:** You're on a product page. You hold ⌃⌥ and say *"Debby, is this a good deal?"* — Debby reads the exact page you're looking at, pulls live prices for the same item elsewhere via context.dev, **points at the price on your screen**, and slides a clean comparison card into the corner showing cheaper sources with the best deal highlighted — citing where each number came from.

**Why this matters (hackathon rubric):** This is the tightest possible fusion of HeyDebby's identity ("sees your screen + points at it") with context.dev live web data. It upgrades **Q2** (a real, visual context.dev fetch mid-demo), **Q3** (why live web data is essential — prices change, and the answer is grounded in the exact page in front of you), and **Q5** (novelty — a voice agent in the notch that draws a live price comparison on your screen).

**Architecture:** Reuses the existing two-pass `FETCH:` loop in `AppState.talk()`. Round 1: the model, given the screenshot **and the live URL of the page you're on**, emits `FETCH:` lines (scrape the current page + search for alternatives). Round 2: with the live data folded back in, the model emits a spoken sentence, a `POINT:` at the on-screen price, and a new `COMPARE:` marker carrying structured JSON. Swift parses `COMPARE:` into a `Beat.compare`, and the `LessonPlayer` plays it in order (after the sentence) by opening a native SwiftUI comparison card. No new network path, no new model loop — one new marker, one new beat, one new overlay.

**Tech Stack:** Swift 6.0.3, macOS 14+, Foundation / AppKit / SwiftUI / ScreenCaptureKit only. **Zero third-party packages.**

---

## Design decisions (resolved)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Trigger | Implicit intent **+** explicit "compare"/"deals" phrase | Natural on-brand invocation, with a guaranteed path so the live demo never misfires. |
| 2 | "The page you're on" | Read frontmost browser URL via a **hardcoded** AppleScript, injected into the prompt; **vision fallback** (product from screenshot) when no URL | Exact page = exact current price (strongest live-web story); still works in non-browser apps via the screenshot. |
| 3 | Fetch strategy | Scrape current page (exact price) **+ one web search** for alternatives, through the existing FETCH loop | One authoritative anchor + a spread of alternatives, ~2 credits, ~1 fetch round. No per-competitor scraping (slow, credit-heavy). |
| 4 | Rendering | **Native comparison card** (`COMPARE:` → `Beat.compare` → SwiftUI card) **+** a `POINT:` at the on-screen price | The model reliably gets aligned tables wrong; a native card is pixel-perfect every time. The POINT keeps Debby's signature identity. |
| 5 | Content | Title = product; rows = "This page" (current) + ≤3 alternatives; columns source / price / note; cheapest highlighted | Useful and uncluttered; fits a small card. |
| 6 | Placement / lifecycle | App-placed **top-right**, auto-hide ~20s, cleared on new turn / New / ✕ | Away from center product imagery and the top-center notch; consistent with annotation auto-hide. |
| 7 | Interaction | **v1 visual, click-through**; rows carry validated `http(s)` URLs | Bulletproof for the demo and true to the click-through overlay ethos. Clickable-to-open is a fast-follow. |
| 8 | Prompt / marker | New `COMPARE:` JSON marker + `comparePrompt`, gated by `debbyWebData` | Same one-line-JSON convention as `DRAW:`/`POINT:`; only offered when a context.dev key exists. |
| 9 | Brains | **All** (claude, claudecli, codex, gemini, openai) | `COMPARE:` is just another reply marker — the FETCH loop already covers every brain, including the streamed one. |
| 10 | Fallbacks | No URL → vision; no alternatives → no card + spoken note; never fabricate prices | Degrade gracefully; the card never shows a lonely single row or invented numbers. |
| 11 | Testing | Pure selfchecks (`COMPARE` parse incl. chunk boundary, best-row pick, browser-script builder) + `--compare-check` flag | Matches the repo's `assert`-in-`runSelfCheck()` + headless-flag pattern; no network in tests. |

---

## Global constraints

- **Zero Swift dependencies.** `Package.swift` gains nothing.
- **Tests are `assert` calls inside `runSelfCheck()`** in `Sources/HeyDebby/main.swift`. There is no XCTest target.
- **The verification command is `./build.sh`** — debug build, `.build/debug/HeyDebby --selfcheck`, release build, ad-hoc codesign. A failed assert aborts it.
- **New Swift files go in `Sources/HeyDebby/`.**
- **The URL-reading AppleScript is hardcoded, never model-written.** The model never supplies AppleScript here — there is no injection surface. It is a read-only query (`get URL of current tab`), not a `RUN:` action, so it does not touch the `RUN` denylist.
- **Scraped pages and search results are untrusted input.** The `COMPARE:` payload is model-written JSON rendered as *text* in a card — no code runs. Any row URL must be validated as `http(s)` before it is ever opened (fast-follow interaction).
- **Never fabricate prices.** The prompt requires every number in the card to come from the live data block, with its source.
- **Gated by the context.dev key.** No key → `debbyWebData` is false → the `comparePrompt` and the URL read are both skipped; behaviour is exactly as today.

---

## Data model

```swift
/// One row of a live price comparison. `current == true` marks the page the user is on;
/// `best == true` marks the cheapest/best option (exactly one row, chosen by the model).
struct ComparisonRow: Codable, Equatable {
    let source: String        // "This page", "Best Buy", "amazon.com"
    let price: String         // "$1,299" — a display string, exactly as seen in live data
    var note: String?         // "M5 · in stock", "+ $100 gift card"
    var url: String?          // http(s) source, validated before use
    var current: Bool?        // the page the user is looking at
    var best: Bool?           // the recommended deal
}

/// A whole comparison card. Emitted by the model as one `COMPARE:` line of JSON.
struct ComparisonCard: Codable, Equatable {
    let title: String         // "MacBook Air 13″ (M-series)"
    let rows: [ComparisonRow]
}
```

`Beat` gains one case:

```swift
enum Beat: Equatable {
    case say(String)
    case draw(ShapeSpec)
    case point(Annotation)
    case run(String)
    case compare(ComparisonCard)   // NEW
}
```

---

### Task 1: `ComparisonCard` model + `COMPARE:` parsing

Pure string/JSON handling, fully testable, nothing else depends on the rest of the feature. Do this first.

**Files:**
- Create: `Sources/HeyDebby/Compare.swift` (the `ComparisonRow` / `ComparisonCard` structs + a `bestRow` helper).
- Edit: `Sources/HeyDebby/Beats.swift` (add `.compare` case; parse `COMPARE:` like `DRAW:`).
- Edit: `Sources/HeyDebby/Claude.swift` (add `ParsedReply.comparisons` view, mirroring `drawings`).
- Test: `Sources/HeyDebby/main.swift`.

**Interfaces:**
- `struct ComparisonCard` / `struct ComparisonRow` (Codable, Equatable) as above.
- `BeatSplitter` recognises a `COMPARE:` line, decodes the JSON, appends `.compare(card)`; on decode failure logs `BEAT COMPARE: did not decode:` and drops it (same posture as `DRAW:`).
- `extension ParsedReply { var comparisons: [ComparisonCard] }`.

**Why it parses like DRAW/POINT.** A `COMPARE:` line is one line of JSON after a keyword — identical shape to the existing markers. It must survive a stream chunk boundary splitting the word `COMPARE` (the same class of bug the FETCH/NEED scanners exist for).

- [ ] **Step 1: Write the failing tests** — add to `runSelfCheck()` in `main.swift`, beside the existing `ContextDev.parseRequest` block:

```swift
    // --- COMPARE: live price comparison card ---
    func splitCompare(_ chunks: [String]) -> [ComparisonCard] {
        var s = BeatSplitter(); var out: [Beat] = []
        for c in chunks { out += s.feed(c) }; out += s.finish()
        return out.compactMap { if case .compare(let c) = $0 { return c } else { return nil } }
    }
    let cmp = splitCompare(["""
    Here are cheaper options.
    COMPARE: {"title":"MacBook Air 13″","rows":[{"source":"This page","price":"$1,299","current":true},{"source":"Best Buy","price":"$1,199","note":"+ gift card","url":"https://bestbuy.com/x","best":true}]}
    """, "\n"])
    assert(cmp.count == 1, "one COMPARE line yields one card")
    assert(cmp.first?.title == "MacBook Air 13″", "title decodes")
    assert(cmp.first?.rows.count == 2, "both rows decode")
    assert(cmp.first?.rows.first?.current == true, "the current-page row is flagged")
    assert(ComparisonCard.bestRow(cmp.first!)?.source == "Best Buy", "the best row is the flagged one")
    // The bug this parser exists for: a stream can split the keyword anywhere.
    let split = splitCompare(["ok.\nCOMP", "ARE: {\"title\":\"X\",\"rows\":[{\"source\":\"a\",\"price\":\"$1\"}]}\n"])
    assert(split.count == 1 && split.first?.title == "X", "a COMPARE marker split across chunks must still parse")
    // Malformed JSON is dropped, not crashed.
    assert(splitCompare(["COMPARE: not json\n"]).isEmpty, "undecodable COMPARE is dropped")
```

- [ ] **Step 2: Run `./build.sh`, confirm it fails** with `cannot find 'ComparisonCard' in scope`.
- [ ] **Step 3: Implement** `Compare.swift` (structs + `static func bestRow(_:) -> ComparisonRow?` returning the `best == true` row, else the numerically-cheapest by parsing digits out of `price`), the `Beat.compare` case, the `COMPARE:` branch in `flushLine()` (copy the `DRAW:` branch), and `ParsedReply.comparisons`.
- [ ] **Step 4: Run `./build.sh`, confirm `selfcheck OK`.**

---

### Task 2: Read the page you're on (`BrowserURL`)

**Files:**
- Create: `Sources/HeyDebby/BrowserURL.swift`.
- Test: `Sources/HeyDebby/main.swift` (pure helpers only — no live AppleScript in tests).

**Interfaces:**
- `enum BrowserURL` with:
  - `static let knownBrowsers: [(app: String, bundleID: String, tabExpr: String)]` — Safari (`URL of current tab of front window`) and the Chromium family: Chrome, Brave, Edge, Arc (`URL of active tab of front window`).
  - `static func script(frontmostBundleID: String) -> String?` — **pure**: given the frontmost app's bundle id, returns the exact AppleScript to run, or nil if it isn't a known browser.
  - `static func current() async -> String?` — resolves the frontmost app (`NSWorkspace.shared.frontmostApplication`), builds the script, runs it via `Control.executablePath` (osascript argv — never a shell), returns a trimmed `http(s)` URL or nil. Any error / non-URL → nil.

**Why hardcoded and read-only.** The script names a browser and asks for a URL. It is never assembled from model output, so there is no injection path. It is a *read*, so it does not go through the `RUN:` denylist. If macOS Automation is denied, osascript errors and we return nil — the caller falls back to vision.

- [ ] **Step 1: Write the failing tests** in `runSelfCheck()`:

```swift
    // --- BrowserURL: frontmost-app → AppleScript, pure ---
    assert(BrowserURL.script(frontmostBundleID: "com.apple.Safari")?
        .contains("current tab of front window") == true, "Safari uses current tab")
    assert(BrowserURL.script(frontmostBundleID: "com.google.Chrome")?
        .contains("active tab of front window") == true, "Chrome uses active tab")
    assert(BrowserURL.script(frontmostBundleID: "com.apple.Preview") == nil,
           "a non-browser frontmost app yields no script (vision fallback)")
```

- [ ] **Step 2: `./build.sh` fails** (`cannot find 'BrowserURL'`).
- [ ] **Step 3: Implement** `BrowserURL.swift`. Run osascript with a short timeout; treat empty/whitespace/non-`http` output as nil.
- [ ] **Step 4: `./build.sh` → `selfcheck OK`.**

---

### Task 3: Prompt — teach comparison + inject the current URL

**Files:**
- Edit: `Sources/HeyDebby/Claude.swift`.

**Interfaces:**
- New `private static let comparePrompt` string, appended (like `fetchPrompt`) only when `webData` is true, inside `promptTemplate(...)`.
- `ParsedReply` already grows `.comparisons` in Task 1; nothing else changes here.

**`comparePrompt` teaches:**
1. When the user asks whether something on a product page is a good deal / cheaper elsewhere (or says "compare" / "deals"), first `FETCH:` the page they're on (its URL is given to you below when available) **and** `FETCH: search: <product> price` for alternatives — reply with ONLY the FETCH lines that round.
2. After the live data arrives, say ONE short sentence, `POINT:` at the price on their screen, then emit exactly one `COMPARE:` line of JSON:
   `COMPARE: {"title":"…","rows":[{"source":"This page","price":"$…","current":true}, {"source":"…","price":"$…","note":"…","url":"https://…","best":true}]}`
3. Rules: every price must come from the live data (never invent one); mark exactly one row `best`; include the real source `url`; ≤3 alternatives; the current page is one row with `current:true`.

- [ ] **Step 1** Add `comparePrompt`; wire it into `promptTemplate` behind `webData`.
- [ ] **Step 2** In the assembled prompt (or the per-turn user text — see Task 4), state: *"The page the user is looking at is: <URL>"* when a URL is available, else *"(no page URL — identify the product from the screenshot.)"*
- [ ] **Step 3** Add a selfcheck asserting `promptTemplate(aspect:1.6, webData:true)` contains `COMPARE:` and `promptTemplate(aspect:1.6, webData:false)` does not (mirror any existing FETCH prompt assertion).
- [ ] **Step 4** `./build.sh` → `selfcheck OK`.

---

### Task 4: Wire the URL into `talk()` and render the card

**Files:**
- Edit: `Sources/HeyDebby/AppState.swift` (inject URL; render `.compare`).
- Edit: `Sources/HeyDebby/Lesson.swift` (add `onCompare`).
- Create/Edit: `Sources/HeyDebby/UI.swift` (the `ComparisonCardWindow` overlay).

**4a — inject the current URL (`talk()`):** where the turn is set up (near `debbyWebData = webData`), if `webData`, read `await BrowserURL.current()` and prepend a context line to the first-round `effectiveText`:
```
[CONTEXT] The page the user is looking at: <url>
```
Only on round 0 (the fetch-follow-up round already carries the data). No URL → omit the line. This is captured once per turn (same snapshot discipline as the screenshot).

**4b — `LessonPlayer.onCompare`:** add `var onCompare: ((ComparisonCard) -> Void)?` and a `case .compare(let c): onCompare?(c)` in `pump()` (fires-and-continues, like `.draw`).

**4c — `attach()`:** add `player.onCompare = { [weak self] card in guard self.chatGeneration == gen else { return }; self.comparison.show(card, on: screen) }`. Also append `.compare` beats to the parsed-beats path (they already flow through `parsed.beats`).

**4d — `ComparisonCardWindow` (UI.swift):** a borderless, non-activating, **click-through** `NSPanel` on the active screen, top-right with margin, holding a SwiftUI card:
- Title row (product).
- One row per `ComparisonRow`: source (left) · note (dim) · price (right, monospaced digits). `current` row gets a subtle "you're here" tag; `best` row gets a green highlight + a small badge.
- Fades in; auto-hides after ~20s (reuse the annotation `scheduleAutoHide` pattern); `func hide()` and cleared when `chatGeneration` bumps (New / ✕ / new turn). Replacing an existing card on a new comparison.

- [ ] **Step 1** Implement 4b, 4c, 4d, then 4a.
- [ ] **Step 2** `./build.sh` → `selfcheck OK`.
- [ ] **Step 3** Manual smoke test (see demo script).

---

### Task 5: Headless diagnostic + notch label

**Files:**
- Edit: `Sources/HeyDebby/main.swift` (`--compare-check`).
- Edit: `Sources/HeyDebby/AppState.swift` (extend `fetchLabel` copy is unchanged; optionally show "Comparing prices · <product>" while the compare fetch is in flight).

**`--compare-check`:** given `DEBBY_PRODUCT` (and optional `DEBBY_URL`), runs the real fetch path — scrape `DEBBY_URL` if set, `ContextDev.search("<product> price")` — and prints the raw rows it would feed the model, proving the live path without the mic/notch/screenshot. Mirror the existing `--context-check` structure (semaphore + `Task.detached`, key read where the app reads it, never printed).

- [ ] **Step 1** Add the flag.
- [ ] **Step 2** `CONTEXT_API_KEY=… DEBBY_PRODUCT="MacBook Air M3" .build/debug/HeyDebby --compare-check` prints live results.

---

### Task 6: Settings + docs

- [ ] No new settings key required (reuses the context.dev key). Optionally add a one-line caption under the context.dev field: *"Enables live answers, fetch, and price comparison."*
- [ ] Update `README.md` and `TECH-SPEC.md`: add the comparison overlay to the feature list and the "why live web data" section; note it reuses the FETCH loop and adds the `COMPARE:` marker + native card.

---

## Verification

- `./build.sh` passes (`selfcheck OK`, release, codesign).
- `--compare-check` prints live rows from context.dev.
- Manual: on a product page, the full path draws the card + points at the price.

## Demo script (for the pitch — Q2/Q3/Q5)

1. Open `apple.com/shop/buy-mac/macbook-air` in Safari.
2. Hold ⌃⌥: *"Debby, is this a good deal?"*
3. Notch shows **"Fetching live from context.dev · apple.com"**, then **"…· MacBook Air price"**.
4. Debby says the current price and **points at it on the page**.
5. A card slides into the top-right: **This page $1,299** · **Best Buy $1,199 + gift card (best)** · one more source — cheapest highlighted, each citing its source.
6. Line to land: *"That's the price on the page in front of you, checked against the live web this second — and it's $100 cheaper two tabs away."*

## Out of scope (fast-follow)

- Clickable rows that open the source URL (validate `http(s)`, `NSWorkspace.shared.open`).
- Per-competitor exact-price scraping (a second FETCH round) when search descriptions lack a number.
- A "source chip" in the notch after a fetch; streaming the card row-by-row.

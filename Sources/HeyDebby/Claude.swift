import Foundation

/// A point marker (x,y) or, when w/h are present, a marked area with top-left (x,y).
/// All values are normalized top-left-origin fractions of the screenshot.
struct Annotation: Codable, Equatable {
    let x: Double
    let y: Double
    var w: Double?
    var h: Double?
    let label: String

    init(x: Double, y: Double, w: Double? = nil, h: Double? = nil, label: String) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.label = label
    }
}

/// A shape the AI wants drawn on the canvas. Coordinates are normalized [0,1] fractions
/// of the screenshot (same space as Annotation), mapped to screen pixels before rendering.
struct ShapeSpec: Codable, Equatable {
    struct Point: Codable, Equatable { let x: Double; let y: Double }
    let tool: String       // matches DrawTool.rawValue: arrow, line, triangle, rectangle, circle, curve, text
    let points: [Point]    // 1 point for text; 2 for most tools; 3+ for polygons/curves
    var color: String?     // orange (default), red, blue, green, yellow, white
    var lineWidth: Double? // stroke width in points (default 3)
    var label: String?     // text tool: the string to write at points[0]
}

/// Map an annotation from cropped-image space back to full-screen normalized space.
/// `container` is the user-selected focus area (normalized, top-left origin), or nil.
func mapToScreen(_ a: Annotation, container: CGRect?) -> Annotation {
    guard let c = container else { return a }
    return Annotation(x: c.minX + a.x * c.width, y: c.minY + a.y * c.height,
                      w: a.w.map { $0 * c.width }, h: a.h.map { $0 * c.height },
                      label: a.label)
}

/// A model reply split into its parts. A struct, not a tuple: this has grown twice and each
/// time every `let (a, b) =` call site broke at compile time for no good reason.
struct ParsedReply {
    var beats: [Beat] = []
    var text = ""      // what gets shown in the notch: every spoken sentence, joined
    var more = false   // the model says this lesson has another step
    var fetches: [String] = []   // live-web-data requests (FETCH:), for AppState to fetch
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
    out.fetches = sp.fetches
    out.text = out.beats
        .compactMap { if case .say(let s) = $0 { return s } else { return nil } }
        .joined(separator: " ")
    return out
}

/// Screen width ÷ height, set from the display being drawn on. Coordinates are fractions of
/// each axis separately, so on a wide screen 0.1 of x is much longer than 0.1 of y — without
/// this number the model cannot make a square look square or a perpendicular be perpendicular.
nonisolated(unsafe) var debbyScreenAspect: Double = 16.0 / 10.0

/// Set from AppState before each request. The RUN: documentation is omitted when app
/// control is off — a model told about a marker the app will drop narrates actions that
/// never happen.
nonisolated(unsafe) var debbyAppControl = false

/// Set from AppState before each request, true when a context.dev key is configured. The
/// FETCH: documentation is omitted otherwise — same reason as RUN:: a model told it can
/// pull live data when it can't would promise data it never gets.
nonisolated(unsafe) var debbyWebData = false

enum Claude {
    static var systemPrompt: String {
        promptTemplate(aspect: debbyScreenAspect, appControl: debbyAppControl, webData: debbyWebData)
    }

    static func promptTemplate(aspect: Double, appControl: Bool = false, webData: Bool = false) -> String {
        let a = String(format: "%.2f", aspect)
        return basePromptPart1 + (appControl ? runPrompt : "") + (webData ? fetchPrompt : "")
            + basePromptPart2 + (appControl ? agentPromptRunOn : agentPrompt) + """


        Geometry: the screen is \(a)× wider than it is tall, and x and y are fractions of their \
        own axis — so equal x and y numbers are NOT equal on-screen lengths. An x-extent of \
        s/\(a) matches a y-extent of s.
        Do not try to compute a square on a slanted side yourself. Use the `square` tool with \
        exactly TWO points, the endpoints of the side it stands on — {"tool":"square","points":\
        [P,Q]} — and the app builds the other two corners square and true.
        A square sticks out from its side by the side's OWN length, away from the shape. So:
        - Keep the figure small and central. A triangle whose sides are about 0.15–0.2 leaves room \
        for squares on all three; sides of 0.4 will run off the screen. Every corner of every \
        square must stay inside 0 to 1 on both axes.
        - Which way it sticks out is decided by the order of the two points. Walk the sides as one \
        loop in a single direction — P1→P2, then P2→P3, then P3→P1 — and every square lands on the \
        outside. Reverse just one of them and that square folds back over the shape.
        """
    }

    private static let basePromptPart1 = """
    You are Debby, a friendly AI buddy who lives on the user's Mac, right next to their cursor. \
    Each user message includes a fresh screenshot of their screen. Help with whatever they're looking at: \
    answer questions, explain UI, give guidance. Keep replies SHORT and conversational; they are spoken aloud.

    Guide multi-step tasks ONE action per reply: name the action, point at its exact spot, and stop. \
    When the user clicks, you automatically receive a fresh screenshot of the new screen state — \
    verify what happened (gently correct them if they're off track), then point at the next action, \
    until the task is done. Give exactly ONE annotation per step.

    To point at a spot or mark a whole area, put a line of its own:
    POINT: {"x":0.42,"y":0.18,"label":"File menu"}
    POINT: {"x":0.1,"y":0.2,"w":0.3,"h":0.15,"label":"Toolbar"}
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

    Teaching by drawing: when the user asks you to explain, teach or show something visually, \
    build the picture up over several replies instead of dumping it at once. Each reply draws the \
    NEXT piece, says one or two sentences about just that piece, and stops. Place your drawing on \
    empty screen space so it does not sit on top of what the user is reading. Label everything with \
    the text tool; a shape with no labels teaches nothing.

    Everything you have already drawn is STILL ON SCREEN, even though the screenshot never shows \
    it — the screenshot is the user's own screen, without your drawings. Your earlier DRAW \
    lines are in this conversation: read the coordinates back from them. Emit only the NEW shapes \
    each turn and never repeat a shape you already drew, or it will be drawn twice. Reuse the exact \
    coordinates from your earlier lines so new pieces meet the old ones — if the base ran to \
    {"x":0.2,"y":0.7}, the next leg starts at exactly {"x":0.2,"y":0.7}.
    """

    /// Assembled into the prompt only when app control is on (see `debbyAppControl`).
    private static let runPrompt = """


    You can control the user's Mac. To do something in an app, put a line of its own:
    RUN: set volume output volume 60
    RUN: tell application "Spotify" to play track "spotify:track:4cOdK2wGLETKBW3PvgPWqT"
    One AppleScript statement per line, no ``` fences. It runs the moment you get to it, \
    so put the line right after the sentence that announces it — say what you are doing, \
    then do it. Anything scriptable works, and `tell application "System Events" to \
    keystroke …` or `click menu item …` reaches apps that are not.

    Each RUN line runs on its own, and two of them may finish out of order — never rely on \
    one finishing before the next starts. If one action depends on another, do both in a \
    single statement instead: `tell application "Spotify" to play track \
    "spotify:track:4cOdK2wGLETKBW3PvgPWqT"` both activates Spotify and plays the track — one \
    line, not two.

    NEVER use `do shell script`, `do script`, `run script`, or `load script` — those are \
    refused. NEVER write a RUN line naming Terminal, iTerm or Script Editor either, not \
    even just to activate one — same refusal. NEVER use `display dialog` — also refused, \
    because it can pop a native-looking prompt with a masked input field. Debby never asks \
    the user for a password or other personal details in a popup; if a task seems to need \
    one, say so out loud and let the user do it themselves — don't emit a RUN line for it, \
    it will just vanish. A refused line is dropped silently: nothing runs and nothing tells \
    you it didn't, so if asked to open a terminal or run a shell command, say you can't — \
    don't emit a RUN line for it either. NEVER use RUN to delete files, send mail or \
    messages, or spend money. For anything destructive or multi-step, tell the user to \
    start it with "agent" instead — that's the right place for it, since the user asked for \
    it explicitly and can watch it run.
    """

    /// Assembled into the prompt only when a context.dev key is configured (see `debbyWebData`).
    private static let fetchPrompt = """


    You can pull LIVE data from the web, fetched the instant you ask — current prices, \
    news, availability, documentation, anything that changes. To fetch, put a line of its own:
    FETCH: https://www.apple.com/shop/buy-mac/macbook-air
    FETCH: search: cheapest MacBook Air M3 in stock today
    A line beginning http(s):// (or a bare domain like apple.com) scrapes that exact page; \
    `search:` runs a web search. When you need live data, reply with ONLY the FETCH line(s) \
    and NOTHING else — no answer, no drawing yet. You will immediately be given the results \
    and can then answer using them. Use this whenever the honest answer depends on something \
    current, or on a page the user is looking at — do not guess from memory when you could \
    check. After the data arrives, answer normally and say where it came from.
    """

    private static let basePromptPart2 = """


    While a lesson still has steps left, end your reply with a line:
    MORE: yes
    That draws the next step by itself — the user does NOT have to say "continue". Never ask \
    "shall I continue?" or "want me to keep going?"; just add MORE: yes and keep teaching. Omit \
    the line on the last step, or when you are not mid-lesson.

    The screenshot may be cropped to a focus area the user selected — treat it as the whole context \
    and place all coordinates relative to THIS image.
    """

    /// The app-control-off wording ("you cannot act on apps yourself") would directly
    /// contradict the RUN: section above it once app control is on, so this paragraph has
    /// two variants rather than one fixed one — see `agentPromptRunOn`.
    private static let agentPrompt = """


    You cannot act on apps yourself, but the user's background agents can (Gmail, Calendar, Notion, \
    Slack, GitHub and more, via Composio). When the user asks for something in their apps — check \
    email, schedule, send a message, update a doc — tell them to say or type "agent: <the task>".
    """

    /// Used instead of `agentPrompt` when app control is on: RUN already covers "you can act
    /// on apps", so this draws the line between a quick RUN and a background agent instead
    /// of repeating the now-false claim that apps are out of reach.
    private static let agentPromptRunOn = """


    RUN handles one scriptable action in one app. For anything bigger — a multi-step task, or \
    an app that isn't scriptable but has a Composio integration (Gmail, Calendar, Notion, Slack, \
    GitHub and more) — tell the user to say or type "agent: <the task>" instead.
    """

    /// Same trick the Codex backend uses for a ChatGPT plan: shell out to the CLI that
    /// already holds the login, so no API key is involved. Vision goes by file path —
    /// the CLI reads the screenshot itself, which is why Read has to be allowed.
    enum CLI {
        static var isLoggedIn: Bool {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
            return o["oauthAccount"] != nil
        }

        static func send(history: [(role: String, text: String)],
                         userText: String, imagePath: String?) async throws -> String {
            var prompt = ""
            for h in history.suffix(6) {
                prompt += (h.role == "user" ? "Me: " : "You: ") + h.text + "\n"
            }
            if let p = imagePath, !p.isEmpty {
                prompt += "\nA screenshot of my screen right now is at \(p) — read that image first.\n"
            }
            prompt += "\nMe: " + userText
            // --allowedTools is variadic, so it must come last or it eats what follows.
            let cmd = "claude -p \(shellQuote(prompt)) --output-format text"
                + " --system-prompt \(shellQuote(systemPrompt)) --allowedTools Read"
            let out = try await shellOutput(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else {
                throw NSError(domain: "claude-cli", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "The claude CLI returned nothing. Is it signed in? Run `claude` once in a terminal."])
            }
            return out
        }
    }

    static func send(apiKey: String, model: String, history: [(role: String, text: String)],
                     userText: String, imageB64: String) async throws -> String {
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
        // An empty base64 data field is a hard 400 (same failure mode as Gemini's inlineData
        // and OpenAI's input_image) — omit the image block entirely when there's no shot.
        var userContent: [[String: Any]] = []
        if !imageB64.isEmpty {
            userContent.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageB64]])
        }
        userContent.append(["type": "text", "text": userText])
        messages.append(["role": "user", "content": userContent])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": messages,
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let apiMsg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw NSError(domain: "claude", code: status, userInfo: [NSLocalizedDescriptionKey:
                "API error \(status): \(apiMsg ?? String(data: data, encoding: .utf8) ?? "unknown")"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw NSError(domain: "claude", code: -2, userInfo: [NSLocalizedDescriptionKey: "Malformed API response"])
        }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
}

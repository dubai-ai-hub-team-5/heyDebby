import AppKit
import SwiftUI

func runSelfCheck() {
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

    let circle = "{\"tool\":\"circle\",\"points\":[{\"x\":0.1,\"y\":0.1},{\"x\":0.2,\"y\":0.2}]}"
    // Decoration must be stripped, not spoken — asserting the count alone hid a bug where
    // the fence characters were welded onto the sentences either side.
    let fenced = splitWhole("Look.\n```json\nDRAW: \(circle)\n```\nDone.")
    assert(fenced.count == 3, "fences must be ignored, not spoken: \(fenced)")
    assert(fenced[0] == .say("Look.") && fenced[2] == .say("Done."),
           "fence characters must not leak into speech: \(fenced)")
    if case .draw(let c) = fenced[1] { assert(c.tool == "circle", "fenced DRAW wrong: \(c)") }
    else { assert(false, "fenced DRAW was lost: \(fenced)") }

    let bold = splitWhole("Look.\n**DRAW:** \(circle)\nDone.")
    assert(bold.count == 3 && bold[0] == .say("Look.") && bold[2] == .say("Done."),
           "a bolded marker must not leak into speech: \(bold)")
    if case .draw = bold[1] {} else { assert(false, "a bolded DRAW must still parse: \(bold)") }

    let bullet = splitWhole("Look.\n- DRAW: \(circle)\nDone.")
    assert(bullet.count == 3 && bullet[0] == .say("Look.") && bullet[2] == .say("Done."),
           "a bulleted marker must not leak a bullet into speech: \(bullet)")
    if case .draw = bullet[1] {} else { assert(false, "a bulleted DRAW must still parse: \(bullet)") }

    // A payload is data, not prose: asterisks inside a label must survive verbatim.
    let starLabel = splitWhole("Note.\nDRAW: {\"tool\":\"text\",\"points\":[{\"x\":0.1,\"y\":0.1}],\"label\":\"very **important** note\"}\nEnd.")
    if case .draw(let sl) = starLabel[1] {
        assert(sl.label == "very **important** note",
               "a label containing ** must not be rewritten: \(sl.label ?? "nil")")
    } else { assert(false, "starred-label DRAW was lost: \(starLabel)") }

    // Prose is spoken, so bold there is noise and must go.
    assert(splitWhole("This is **really** important.") == [.say("This is really important.")],
           "bold must be stripped from spoken prose: \(splitWhole("This is **really** important."))")

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

    // --- LessonPlayer: a shape waits for the sentence in front of it ---
    let lp = LessonPlayer()
    var played: [String] = []
    lp.onSay = { played.append("say:\($0)") }
    lp.onDraw = { played.append("draw:\($0.tool)") }
    lp.onPoint = { played.append("point:\($0.label)") }
    var idleCount = 0
    lp.onIdle = { idleCount += 1 }

    let lineShape = ShapeSpec(tool: "line", points: [.init(x: 0, y: 0), .init(x: 1, y: 1)],
                              color: nil, lineWidth: nil, label: nil)
    lp.append([.say("one"), .draw(lineShape), .say("two")])
    assert(played == ["say:one"],
           "nothing may play while a sentence is still being spoken: \(played)")
    lp.speechFinished()
    assert(played == ["say:one", "draw:line", "say:two"],
           "the shape must land between its two sentences: \(played)")
    assert(idleCount == 0, "still speaking — not idle yet")
    lp.speechFinished()
    lp.closeStream()
    assert(idleCount == 1, "queue drained and stream closed means idle")

    // onIdle drives auto-advance: a second fire burns a lesson step and an API call.
    lp.speechFinished()          // extra callback after the lesson already ended
    lp.speechFinished()
    assert(idleCount == 1, "onIdle must fire exactly once, got \(idleCount)")

    // A cancel that arrives while nothing is speaking belongs to someone else.
    let lp4 = LessonPlayer()
    var played4: [String] = []
    lp4.onSay = { played4.append("say:\($0)") }
    lp4.onDraw = { played4.append("draw:\($0.tool)") }
    lp4.speechFinished()         // stray callback before anything was queued
    lp4.append([.say("a"), .draw(lineShape)])
    assert(played4 == ["say:a"], "a stray speechFinished must not advance the queue: \(played4)")

    // A cancelled lesson must go quiet and must never auto-advance.
    let lp5 = LessonPlayer()
    var played5: [String] = []
    var idle5 = 0
    lp5.onSay = { played5.append("say:\($0)") }
    lp5.onDraw = { played5.append("draw:\($0.tool)") }
    lp5.onIdle = { idle5 += 1 }
    lp5.append([.say("one"), .draw(lineShape), .say("two")])
    lp5.cancel()
    lp5.speechFinished()
    lp5.closeStream()
    assert(played5 == ["say:one"], "cancel must stop playback: \(played5)")
    assert(idle5 == 0, "a cancelled lesson must not auto-advance")

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

    // A right triangle can't come from a bounding box — 3 points must reach the path as given.
    let tri = DrawnShape(tool: .triangle,
                         points: [CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 100)],
                         color: .orange, lineWidth: 3)
    assert(tri.buildPath().boundingRect == CGRect(x: 0, y: 0, width: 80, height: 100),
           "3-point triangle must use its own vertices: \(tri.buildPath().boundingRect)")
    assert(DrawnShape(tool: .text, points: [.zero], color: .orange, lineWidth: 3, label: "a")
        .buildPath().isEmpty, "text is drawn as text, never stroked")
    assert(!DrawTool.manual.contains(.text), "no way to type a label by hand — keep it out of the toolbar")
    // A square on a hypotenuse is rotated; rectangle is axis-aligned, so polygon is the only
    // tool that can express it. It must close, and it must keep every vertex.
    let sq = DrawnShape(tool: .polygon,
                        points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40),
                                 CGPoint(x: -10, y: 70), CGPoint(x: -40, y: 30)],
                        color: .red, lineWidth: 3)
    assert(sq.buildPath().boundingRect == CGRect(x: -40, y: 0, width: 70, height: 70),
           "rotated square must keep all 4 vertices: \(sq.buildPath().boundingRect)")
    var sqClosed = false
    sq.buildPath().forEach { if case .closeSubpath = $0 { sqClosed = true } }
    assert(sqClosed, "polygon must close back to its first point")

    // The square tool does the perpendicular the model kept getting wrong: given the side
    // (0,0)→(30,40) it must produce a true 50×50 square standing on it, not a parallelogram.
    let onSide = DrawnShape(tool: .square, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40)],
                            color: .blue, lineWidth: 3)
    assert(onSide.buildPath().boundingRect == CGRect(x: -40, y: 0, width: 70, height: 70),
           "square on a slanted side is wrong: \(onSide.buildPath().boundingRect)")
    let flipped = DrawnShape(tool: .square, points: [CGPoint(x: 30, y: 40), CGPoint(x: 0, y: 0)],
                             color: .blue, lineWidth: 3)
    assert(flipped.buildPath().boundingRect == CGRect(x: 0, y: -30, width: 70, height: 70),
           "swapping the endpoints must flip which side the square stands on")

    assert(agentTask(from: "agent: clean up my desktop") == "clean up my desktop")
    assert(agentTask(from: "Hey Debby Agent build me a webpage") == "build me a webpage")
    assert(agentTask(from: "what does this button do") == nil)
    assert(agentTask(from: "agents are cool right") == nil)
    assert(shellQuote("it's") == "'it'\\''s'")
    let cx = agentCommand(backend: "codex", task: "hi", screenshotPath: "/tmp/s.jpg", fullAccess: false)
    assert(cx.contains("codex exec --skip-git-repo-check") && cx.contains("-i '/tmp/s.jpg'")
           && cx.contains("-s read-only") && cx.hasSuffix("'hi'"), "codex cmd wrong: \(cx)")
    assert(agentCommand(backend: "codex", task: "hi", screenshotPath: nil, fullAccess: true)
        .contains("--dangerously-bypass-approvals-and-sandbox"))
    assert(agentCommand(backend: "claude", task: "hi", screenshotPath: nil, fullAccess: true)
        .contains("claude -p --dangerously-skip-permissions"))
    // Without an allowlist `claude -p` denies every tool, so app tasks fail silently.
    // The prompt must come before --allowedTools, which is variadic and eats what follows.
    let cl = agentCommand(backend: "claude", task: "email bob", screenshotPath: nil, fullAccess: false)
    assert(cl.hasSuffix("--allowedTools mcp__composio Read Glob Grep"), "claude agent needs tools: \(cl)")
    assert(cl.range(of: "'email bob'")!.upperBound <= cl.range(of: "--allowedTools")!.lowerBound,
           "prompt must precede the variadic flag: \(cl)")
    let mid = mapToScreen(Annotation(x: 0.5, y: 0.5, label: "t"),
                          container: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    assert(abs(mid.x - 0.5) < 1e-9 && abs(mid.y - 0.5) < 1e-9, "container center mapping wrong")
    let corner = mapToScreen(Annotation(x: 0.0, y: 1.0, label: "t"),
                             container: CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.6))
    assert(abs(corner.x - 0.2) < 1e-9 && abs(corner.y - 0.7) < 1e-9, "container corner mapping wrong")
    let noC = mapToScreen(Annotation(x: 0.3, y: 0.4, label: "t"), container: nil)
    assert(noC.x == 0.3 && noC.y == 0.4)
    let ra = mapToScreen(Annotation(x: 0.0, y: 0.0, w: 0.5, h: 0.5, label: "t"),
                         container: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    assert(abs(ra.x - 0.5) < 1e-9 && abs((ra.w ?? 0) - 0.25) < 1e-9 && abs((ra.h ?? 0) - 0.25) < 1e-9,
           "area container mapping wrong")

    assert(isTalkChord([.control, .option]), "⌃⌥ is the talk chord")
    assert(isTalkChord([.control, .option, .capsLock]), "caps lock must not block talking")
    assert(!isTalkChord([.control]) && !isTalkChord([.option]), "one modifier is not the chord")
    assert(!isTalkChord([.control, .option, .command]) && !isTalkChord([.control, .option, .shift]),
           "⌘/⇧ means the user is driving an app shortcut, not talking")

    // Auto prefers a subscription that's already signed in; the API key is the last resort.
    assert(resolveBackend("", codex: true, claudeCLI: true) == "codex")
    assert(resolveBackend("", codex: false, claudeCLI: true) == "claudecli")
    assert(resolveBackend("", codex: false, claudeCLI: false) == "claude")
    assert(resolveBackend("claudecli", codex: true, claudeCLI: false) == "claudecli", "explicit choice wins")
    assert(resolveBackend("garbage", codex: false, claudeCLI: true) == "claudecli", "unknown value means Auto")

    assert(micLevel(rms: 0) == 0 && micLevel(rms: 1) == 1, "mic level must clamp to 0…1")
    assert(micLevel(rms: 0.03) > 0.25 && micLevel(rms: 0.03) < 0.6, "speaking voice should sit mid-scale")
    assert(micLevel(rms: 0.0005) == 0, "a quiet room must not wiggle the bars")

    // Notch surface: top-centred on the screen, growing downward when it opens.
    let scr = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let shut = notchRect(screen: scr, collapsed: CGSize(width: 200, height: 32), expanded: false)
    assert(shut == CGRect(x: 400, y: 768, width: 200, height: 32), "collapsed notch rect wrong: \(shut)")
    let open = notchRect(screen: scr, collapsed: CGSize(width: 200, height: 32), expanded: true)
    assert(open.maxY == scr.maxY && open.midX == scr.midX && open.width == NotchMetrics.expanded.width,
           "open notch must stay pinned to the top centre: \(open)")
    assert(open.contains(CGPoint(x: 500, y: 760)) && !shut.contains(CGPoint(x: 500, y: 760)),
           "opening must widen the hover target")
}

if CommandLine.arguments.contains("--selfcheck") {
    runSelfCheck()
    print("selfcheck OK")
    exit(0)
}

// What the HUD measured on this Mac's display (the one thing that differs per machine),
// plus `--notchcheck out.png` to render the HUD offscreen and eyeball it without a screenshot.
if let i = CommandLine.arguments.firstIndex(of: "--notchcheck") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let s = NSScreen.notchHost
        print("screen \(s.frame) safeTop \(s.safeAreaInsets.top) aux \(String(describing: s.auxiliaryTopLeftArea))")
        print("collapsed \(s.collapsedNotch)")
        DebbyLog.write("notchcheck")
        print("log \(DebbyLog.url.path) exists=\(FileManager.default.fileExists(atPath: DebbyLog.url.path))")
        // Not checking AXIsProcessTrusted here: run from a shell, TCC attributes the
        // check to the parent shell and always says no. The app logs the real answer
        // at launch — `log show --predicate 'process == "HeyDebby"'`.
        print("shut \(notchRect(screen: s.frame, collapsed: s.collapsedNotch, expanded: false))")
        print("open \(notchRect(screen: s.frame, collapsed: s.collapsedNotch, expanded: true))")
        guard CommandLine.arguments.count > i + 1 else { return }
        // Settings is its own window sized from fittingSize — a zero size here means a broken window.
        print("settings fits \(NSHostingView(rootView: SettingsView()).fittingSize)")
        if let png = ImageRenderer(content: SettingsView().background(Color(white: 0.92))).nsImage?
            .tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1] + ".settings.png"))
        }
        let state = AppState()
        state.isListening = true
        state.partial = "why is this build failing"
        state.container = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
        state.levels = (0..<28).map { CGFloat(abs(sin(Double($0) * 0.8)) * 0.85 + 0.1) }
        let sheet = VStack(spacing: 12) {
            NotchView().environmentObject(state)
            // The pointer at 4x, triangle vs. listening — they must occupy the same box.
            HStack(spacing: 40) {
                DebbyPointerView().environmentObject(AppState())
                DebbyPointerView().environmentObject(state)
            }
            .scaleEffect(4)
            .frame(height: 140)
        }
        .frame(width: 520, height: 360)
        .background(Color(white: 0.35))
        let r = ImageRenderer(content: sheet)
        r.scale = 2
        if let png = r.nsImage?.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?
            .representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            print("wrote \(CommandLine.arguments[i + 1])")
        }
    }
    exit(0)
}

// Headless check of the Codex-subscription link: prints only the model's reply.
if CommandLine.arguments.contains("--codex-check") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let env = ProcessInfo.processInfo.environment
            let imgB64 = env["DEBBY_IMG"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)).base64EncodedString() }
            let reply = try await Codex.send(model: env["DEBBY_MODEL"] ?? Codex.defaultModel, history: [],
                                             userText: env["DEBBY_PROMPT"] ?? "Reply with exactly: CODEX LINK OK",
                                             imageB64: imgB64)
            print(reply)
        } catch {
            print("ERR: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Headless check of the Gemini link: prints the reply and what parsed out of it, so a
// "why didn't it draw" can be answered without the notch, a screenshot or the mic.
// Key comes from the same place the app reads it; it is never printed.
if CommandLine.arguments.contains("--gemini-check") {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var parsed: [ShapeSpec] = []   // handed to the main thread after sem.wait()
    Task.detached {
        let env = ProcessInfo.processInfo.environment
        let stored = UserDefaults.standard.string(forKey: "geminiApiKey") ?? ""
        let key = stored.isEmpty ? (env["GOOGLE_API_KEY"] ?? env["GEMINI_API_KEY"] ?? "") : stored
        let model = env["DEBBY_MODEL"] ?? UserDefaults.standard.string(forKey: "geminiModel") ?? ""
        guard !key.isEmpty else { print("ERR: no Gemini key configured"); sem.signal(); return }
        do {
            let imgB64 = env["DEBBY_IMG"].flatMap {
                try? Data(contentsOf: URL(fileURLWithPath: $0)).base64EncodedString()
            } ?? ""
            // DEBBY_PROMPT2 replays a second turn with the first reply in history — the only way
            // to check that step 2 of a diagram lands on step 1 rather than somewhere new.
            var history: [(role: String, text: String)] = []
            var turns = [env["DEBBY_PROMPT"] ?? "Teach me the Pythagorean theorem by drawing it."]
            if let p2 = env["DEBBY_PROMPT2"] { turns.append(p2) }
            for (n, userText) in turns.enumerated() {
                let reply = try await Gemini.send(apiKey: key, model: model, history: history,
                                                  userText: userText, imageB64: imgB64)
                let p = parseReply(reply)
                print("--- turn \(n + 1) reply ---\n\(reply)")
                print("--- parsed --- spoken=\(p.text.count) chars, annotations=\(p.annotations.count),"
                      + " drawings=\(p.drawings.count), more=\(p.more)")
                for d in p.drawings { print("  \(d.tool) pts=\(d.points.count) label=\(d.label ?? "-")") }
                history.append((role: "user", text: userText))
                history.append((role: "assistant", text: reply))  // same as AppState: JSON kept
                parsed += p.drawings                               // canvas accumulates, so does this
            }
        } catch {
            print("ERR: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    // DEBBY_OUT=x.png renders what would land on screen — parsing right and painting right are
    // different failures. Must run here: the render is main-actor work and sem.wait() owns the
    // main thread, so doing it inside the task above deadlocks.
    if let out = ProcessInfo.processInfo.environment["DEBBY_OUT"], !parsed.isEmpty {
        MainActor.assumeIsolated {
            let size = CGSize(width: 1200, height: 800)
            let c = DrawingController()
            c.shapes = parsed.compactMap { s in
                guard let tool = DrawTool(rawValue: s.tool),
                      s.points.count >= (tool == .text ? 1 : 2) else { return nil }
                return DrawnShape(tool: tool,
                                  points: s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) },
                                  color: .orange, lineWidth: CGFloat(s.lineWidth ?? 3),
                                  label: s.label ?? "")
            }
            let view = DrawingCanvasView(controller: c, size: size, interactive: false)
                .background(Color(white: 0.15))
            let r = ImageRenderer(content: view)
            if let png = r.nsImage?.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?
                .representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("wrote \(out) (\(c.shapes.count) shapes)")
            }
        }
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var statusItem: NSStatusItem!
    var notch: NotchWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "👆"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(talk)

        notch = NotchWindow(state: state)
        state.notch = notch
        state.pointer.start(state: state)

        Hotkey.watchTalkChord { [weak self] down, held in
            self?.state.talkChord(down: down, heldFor: held)
        }

        // Registers the app in System Settings → Screen Recording and shows the
        // system prompt once if not yet granted (grant requires an app relaunch).
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        // ⌃⌥ is a modifier-only chord, so it's read from the global event stream —
        // that needs Accessibility. Prompts if missing; the grant needs a relaunch.
        let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSLog("HeyDebby: accessibility=\(ax) — ⌃⌥ hold-to-talk is dead without it")
    }

    @objc func talk() { state.toggleListening() }

    // Re-opening the app (Dock/Finder/`open`) starts listening.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.toggleListening()
        return false
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

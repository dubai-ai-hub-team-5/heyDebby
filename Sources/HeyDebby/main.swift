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

    // --- RUN: app control ---
    let vol = splitWhole("Turning it up.\nRUN: set volume output volume 60\nDone.")
    assert(vol.count == 3, "RUN must be its own beat: \(vol)")
    assert(vol[0] == .say("Turning it up.") && vol[2] == .say("Done."),
           "a RUN line must not be spoken: \(vol)")
    assert(vol[1] == .run("set volume output volume 60"), "RUN payload wrong: \(vol[1])")

    // The payload is handed to osascript verbatim — quoting and punctuation must survive.
    let track = splitWhole("RUN: tell application \"Spotify\" to play track \"spotify:track:1\"")
    assert(track == [.run("tell application \"Spotify\" to play track \"spotify:track:1\"")],
           "quotes and colons inside a RUN payload must survive: \(track)")

    // AppleScript can shell out. The payload is model-written and the model reads the
    // user's screen, so a page saying this is a live injection path — drop it at the parser.
    assert(splitWhole("RUN: do shell script \"rm -rf ~\"") == [],
           "do shell script must never become a beat")
    assert(splitWhole("RUN: DO SHELL SCRIPT \"rm -rf ~\"") == [],
           "the shell-out check is case-insensitive")
    assert(splitWhole("RUN: tell app \"Terminal\" to do script \"rm -rf ~\"") == [],
           "do script opens a Terminal window running a command — same hole")

    // Ordering: a RUN between two sentences plays between them, not at the end.
    let order = splitWhole("First.\nRUN: beep\nSecond.\nRUN: beep 2\nThird.")
    assert(order.count == 5 && order[1] == .run("beep") && order[3] == .run("beep 2"),
           "RUN beats must keep their position in the narration: \(order)")

    // AppleScript ignores whitespace between tokens; the check must too.
    assert(splitWhole("RUN: do  shell   script \"id\"") == [],
           "extra spaces must not slip past the rail")
    assert(splitWhole("RUN: do\tshell\tscript \"id\"") == [],
           "tabs must not slip past the rail")
    // The eval primitives, which can build the other forbidden phrases at runtime.
    assert(splitWhole("RUN: run script (\"do sh\" & \"ell script \\\"id\\\"\")") == [],
           "run script is eval — it defeats any lexical check downstream of it")
    assert(splitWhole("RUN: load script file \"/tmp/x.scpt\"") == [],
           "load script + run is the same hole in two steps")
    // Telling a terminal is shell access wearing a hat.
    assert(splitWhole("RUN: tell application \"Terminal\" to activate") == [],
           "no talking to terminal emulators")
    // The things we actually want must still work.
    assert(splitWhole("RUN: set volume output volume 60")
           == [.run("set volume output volume 60")], "volume must still work")
    assert(splitWhole("RUN: tell application \"Spotify\" to playpause")
           == [.run("tell application \"Spotify\" to playpause")], "Spotify must still work")
    assert(splitWhole("RUN: tell application \"System Events\" to keystroke \"n\" using command down")
           == [.run("tell application \"System Events\" to keystroke \"n\" using command down")],
           "System Events must still work — it is how non-scriptable apps are reached")

    // Known and accepted: GUI scripting is allowed, so RUN: is not a boundary against a
    // determined injection. This asserts the limit deliberately — if it ever starts
    // failing, someone tightened the rail and the settings copy needs to change with it.
    // Asserting the exact beat (not just a count of 1) matters: deleting the whole RUN:
    // branch also yields exactly one beat — a .say of the fallen-through prose line —
    // so a bare `.count == 1` would stay green even with the branch gone.
    let keystroke = splitWhole("RUN: tell application \"System Events\" to keystroke \"t\" using command down")
    assert(keystroke == [.run("tell application \"System Events\" to keystroke \"t\" using command down")],
           "keystroke injection is knowingly allowed; see shellsOut's comment")

    // The bypasses that are NOT accepted.
    assert(splitWhole("RUN: tell application id \"com.apple.Terminal\" to activate") == [],
           "a terminal named by bundle id must still be refused")
    assert(splitWhole("RUN: tell application \"Terminal.app\" to activate") == [],
           "a terminal named with a .app suffix must still be refused")

    // Raw four-char event codes contain none of the denylisted keywords and reach the
    // same places `do shell script` does — demonstrated live with
    // `osascript -e '«event sysoexec» "id -un"'`. Any use of the raw-code syntax is refused.
    assert(splitWhole("RUN: «event sysoexec» \"touch /tmp/pwned; id -un\"") == [],
           "raw four-char event codes must be refused — they carry no denylisted keyword")
    assert(splitWhole("RUN: tell application id \"«event sysoexec»\" to activate") == [],
           "a guillemet anywhere in the payload is refused, not just at the start")
    // An ordinary payload with neither guillemet must be unaffected by the new check.
    assert(splitWhole("RUN: tell application \"Spotify\" to playpause")
           == [.run("tell application \"Spotify\" to playpause")],
           "a payload containing neither guillemet must still pass")

    // `display dialog` is a zero-permission, native-looking prompt that can carry a masked
    // "hidden answer" field — a credential-phishing primitive reachable from on-screen text,
    // not a shell-out, but refused for the same reason: it must never become a beat.
    assert(splitWhole("RUN: display dialog \"macOS needs your password to continue\" with hidden answer") == [],
           "display dialog must be refused — it's a masked-input credential prompt")
    assert(splitWhole("RUN: display dialog \"Enter your name\" default answer \"\"") == [],
           "display dialog is refused wholesale, even without hidden answer")
    // A nearby, legitimate payload that must still pass: display notification carries no
    // text field at all, so it isn't the phishing shape and shouldn't be caught in the net.
    assert(splitWhole("RUN: display notification \"Volume set to 60%\"")
           == [.run("display notification \"Volume set to 60%\"")],
           "display notification has no text field and must still work")

    // --- CRLF: a PTY-wrapped subprocess writes \r\n, not \n ---
    // The whole lesson, replayed with CRLF line endings in one chunk, must produce the
    // exact same beats. Swift fuses a same-chunk "\r\n" into one grapheme cluster distinct
    // from "\n" — a naive `ch == "\n"` check never matches it, so without the fix nothing
    // in this string would flush mid-stream at all; only `finish()`'s single trailing
    // flushLine() would run, on the whole glued blob, producing one garbled prose beat.
    let crlfLesson = lesson.replacingOccurrences(of: "\n", with: "\r\n")
    assert(splitWhole(crlfLesson) == lb,
           "CRLF line endings must not change the beats: \(splitWhole(crlfLesson))")
    // The marker path specifically, not just prose: a CRLF-terminated RUN: line.
    let crlfRun = splitWhole("Turning it up.\r\nRUN: set volume output volume 60\r\nDone.")
    assert(crlfRun == vol, "a CRLF-terminated RUN line must parse the same as an LF one: \(crlfRun)")
    // CRLF-separated prose must still split into two sentences, not one glued blob.
    let crlfProse = splitWhole("First sentence.\r\nSecond sentence.\r\n")
    assert(crlfProse == [.say("First sentence."), .say("Second sentence.")],
           "CRLF between sentences must not glue them together: \(crlfProse)")

    // --- Control: argv, not a shell string ---
    // The executable is the branch's headline security property: swapping it for
    // /bin/zsh with a joined command string would keep every `arguments` assertion below
    // green while reopening the exact hole AgentRunner.spawn's zsh -lc path has.
    assert(Control.executablePath == "/usr/bin/osascript",
           "statements must run through osascript, never a shell")
    assert(Control.arguments(for: ["set volume output volume 60"])
           == ["-e", "set volume output volume 60"], "one statement, one -e pair")
    assert(Control.arguments(for: ["a", "b"]) == ["-e", "a", "-e", "b"],
           "statements run in order, each its own -e")
    // The whole point of an arguments array: shell metacharacters are inert data.
    let nasty = "tell app \"X\" to y'; rm -rf ~; echo '"
    assert(Control.arguments(for: [nasty]) == ["-e", nasty],
           "a payload with shell metacharacters must arrive verbatim, unquoted and unsplit")

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
    // speechFinished() alone never reaches pump() once idle (guard speaking blocks it) —
    // closeStream() is a second route into pump() that doesn't go through that guard, so
    // this is what actually exercises the idleFired latch.
    lp.closeStream()
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
    // A streamed reply keeps arriving for seconds after ⌃⌥ interrupts it. Those deltas must
    // not resurrect the lesson — that draws shapes and talks into a live microphone.
    lp5.append([.say("three"), .draw(lineShape)])
    assert(played5 == ["say:one"], "a cancelled lesson must ignore late beats: \(played5)")

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

    // A .run beat fires in order and does not block what follows, unlike .say.
    let lp6 = LessonPlayer()
    var played6: [String] = []
    lp6.onSay = { played6.append("say:\($0)") }
    lp6.onRun = { played6.append("run:\($0)") }
    lp6.append([.run("beep"), .say("hello"), .run("beep 2")])
    assert(played6 == ["run:beep", "say:hello"],
           "a run before a sentence fires immediately; the one after it waits: \(played6)")
    lp6.speechFinished()
    assert(played6 == ["run:beep", "say:hello", "run:beep 2"],
           "the trailing run fires once the sentence ends: \(played6)")

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
    let cx = agentCommand(backend: "codex", task: "hi", screenshotPath: "/tmp/s.jpg", fullAccess: false, appControl: true)
    assert(cx.contains("codex exec --skip-git-repo-check") && cx.contains("-i '/tmp/s.jpg'")
           && cx.contains("-s read-only") && cx.hasSuffix("'hi'"), "codex cmd wrong: \(cx)")
    assert(agentCommand(backend: "codex", task: "hi", screenshotPath: nil, fullAccess: true, appControl: true)
        .contains("--dangerously-bypass-approvals-and-sandbox"))
    assert(agentCommand(backend: "claude", task: "hi", screenshotPath: nil, fullAccess: true, appControl: false)
        .contains("claude -p --dangerously-skip-permissions"))
    // Without an allowlist `claude -p` denies every tool, so app tasks fail silently.
    // The prompt must come before --allowedTools, which is variadic and eats what follows.
    let cl = agentCommand(backend: "claude", task: "email bob", screenshotPath: nil, fullAccess: false, appControl: true)
    assert(cl.hasSuffix("--allowedTools mcp__composio Read Glob Grep Bash(osascript:*)"),
           "claude agent needs tools: \(cl)")
    assert(cl.range(of: "'email bob'")!.upperBound <= cl.range(of: "--allowedTools")!.lowerBound,
           "prompt must precede the variadic flag: \(cl)")

    // Agents get scoped shell for AppleScript — not bare Bash — and ONLY when the user has
    // switched app control on. An agent's osascript call runs raw, never through
    // BeatSplitter's refusal list, so this grant must not be a second, ungated door into
    // the same capability the RUN: rail exists to gate.
    let ag = agentCommand(backend: "claude", task: "play some music",
                          screenshotPath: nil, fullAccess: false, appControl: true)
    assert(ag.contains("Bash(osascript:*)"),
           "app control on: the claude agent needs scoped osascript for app tasks: \(ag)")
    assert(ag.range(of: "'play some music'")!.upperBound
           <= ag.range(of: "--allowedTools")!.lowerBound,
           "--allowedTools is variadic and must stay last")
    let agOff = agentCommand(backend: "claude", task: "play some music",
                             screenshotPath: nil, fullAccess: false, appControl: false)
    assert(!agOff.contains("osascript"),
           "app control off: the agent grant must not include osascript either: \(agOff)")
    // Full access already implies everything; the scoped entry would be noise.
    assert(!agentCommand(backend: "codex", task: "hi", screenshotPath: nil, fullAccess: false, appControl: true)
            .contains("osascript"), "codex agents are unaffected")

    // The marker is documented only when the feature is on. A model told about a marker
    // the app will drop announces actions that never happen.
    assert(Claude.promptTemplate(aspect: 1.6, appControl: true).contains("RUN:"),
           "app control on must document the marker")
    assert(!Claude.promptTemplate(aspect: 1.6, appControl: false).contains("RUN:"),
           "app control off must not mention the marker")
    assert(Claude.promptTemplate(aspect: 1.6, appControl: true).contains("do shell script"),
           "the prompt must tell the model the shell escape is refused")
    // Adjacent RUN: lines are not serialized (each spawns its own osascript process) even
    // with voice replies off, when .say never blocks the queue either — so the prompt must
    // not claim a sentence in between guarantees order, only that a single statement does.
    let runOnPrompt = Claude.promptTemplate(aspect: 1.6, appControl: true)
    assert(runOnPrompt.contains("finish out of order") && runOnPrompt.contains("single statement"),
           "the prompt must warn RUN lines can race and point at one statement, not a sentence, as the fix")
    assert(!runOnPrompt.contains("always finishes before the next line runs"),
           "the ordering claim must not promise something LessonPlayer doesn't deliver when voiceReplies is off")
    // The prompt's refusal list must name every form the parser actually refuses, or a model
    // asked for a refused one emits a RUN line that is silently dropped and narrates success.
    for term in BeatSplitter.refusedForms {
        assert(runOnPrompt.localizedCaseInsensitiveContains(term),
               "prompt must document refused form: \(term)")
    }
    // "You cannot act on apps yourself" (the agent-routing paragraph) would directly
    // contradict the RUN: section once app control is on — it must not appear together
    // with RUN:, and RUN:'s absence must not lose the agent-routing guidance either.
    assert(!Claude.promptTemplate(aspect: 1.6, appControl: true).contains("cannot act on apps"),
           "app control on must not still claim apps are out of reach")
    assert(Claude.promptTemplate(aspect: 1.6, appControl: true).contains("agent:"),
           "app control on must still route multi-step work to an agent")
    assert(Claude.promptTemplate(aspect: 1.6, appControl: false).contains("cannot act on apps"),
           "app control off keeps the original agent-only framing")
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
    assert(resolveBackend("openai", codex: true, claudeCLI: true) == "openai",
           "an explicitly chosen brain must win over auto-detection")

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
    // SSE only strips one leading space after the colon if present — a server (or a
    // future OpenAI SDK revision) is free to omit it. Codex.swift's parser for this same
    // endpoint family already tolerates that; this one must not silently drop the delta.
    assert(OpenAI.delta(fromSSELine:
        "data:{\"type\":\"response.output_text.delta\",\"delta\":\"Hy\",\"sequence_number\":1}") == "Hy",
        "a missing space after 'data:' must not swallow the delta")
    // The [DONE] sentinel check must compare the whole line, not search inside it — a
    // delta whose actual text happens to be "[DONE]" is still real text to speak.
    assert(OpenAI.delta(fromSSELine:
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"[DONE]\",\"sequence_number\":2}") == "[DONE]",
        "a delta whose text is literally [DONE] must still come through")
    // Other *.delta events carry a "delta" field too — only output_text is speech.
    assert(OpenAI.delta(fromSSELine:
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking out loud\"}") == nil,
        "a reasoning-summary delta must not reach the user's ears")
    assert(OpenAI.delta(fromSSELine:
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"a\\\":1}\"}") == nil,
        "a function-call-arguments delta is not speech")

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

    var fs = NeedScanner()
    _ = fs.feed("NEED: last line, no newline")
    assert(fs.flush() == "last line, no newline", "flush must catch the unterminated last line")
    assert(fs.flush() == nil, "flush twice must not fire twice")

    // A case the given tests don't cover: the given split-across-chunks test breaks the
    // marker in two, both pieces still inside the word "NEED". Break it into one chunk per
    // character instead, so the buffer has to carry state across many feed() calls in a
    // row, including a break right at the colon and right after it.
    let needLine = "NEED: split one character at a time\n"
    assert(scanAll(needLine.map { String($0) }) == "split one character at a time",
           "a marker fed one character per chunk must still be found")

    // CRLF: a PTY-wrapped subprocess writes "\r\n". Swift fuses a same-chunk "\r\n" into
    // one grapheme cluster distinct from plain "\n" — a naive `ch == "\n"` check never
    // fires on it, the line never terminates, and the gate never opens.
    assert(scanAll(["Filling the form…\r\nNEED: Ready to submit — please confirm.\r\n"])
           == "Ready to submit — please confirm.", "a CRLF-terminated marker must still be found")
    // The pathological split: the chunk boundary falls between \r and \n, so each arrives
    // as its own standalone character rather than a fused pair. This must resolve the line
    // on the \r alone, immediately — checking the *final* accumulated text isn't enough to
    // prove that, because a wide trim can silently mop up a \r that leaked in too late; the
    // first feed() call has to already return the hit.
    var crSplit = NeedScanner()
    assert(crSplit.feed("NEED: split right at the carriage return\r")
           == "split right at the carriage return",
           "a lone \\r must terminate the line immediately, without waiting for a \\n")
    assert(crSplit.feed("\n") == nil, "the paired \\n arriving after must not fire a second time")
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

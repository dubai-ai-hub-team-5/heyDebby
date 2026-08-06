import AppKit
import Foundation
import SwiftUI

/// "agent: do X" / "hey debby agent do X" -> "do X"; anything else -> nil
func agentTask(from text: String) -> String? {
    let lower = text.lowercased()
    for prefix in ["hey debby agent", "heydebby agent", "debby agent", "agent"] {
        guard lower.hasPrefix(prefix) else { continue }
        let rest = text.dropFirst(prefix.count)
        if let c = rest.first, !" ,:;—-".contains(c) { continue }
        let task = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;—-\n"))
        return task.isEmpty ? nil : task
    }
    return nil
}

/// "codex" (ChatGPT plan via the Codex CLI), "claudecli" (Claude plan via the claude
/// CLI), "claude" (Anthropic API key), "gemini" (Google AI API key), or "openai"
/// (OpenAI API key, the only streamed one). Anything else means Auto: prefer whichever
/// subscription is already signed in.
func resolveBackend(_ stored: String,
                    codex: Bool = Codex.isLoggedIn,
                    claudeCLI: Bool = Claude.CLI.isLoggedIn) -> String {
    if ["codex", "claude", "claudecli", "gemini", "openai"].contains(stored) { return stored }
    if codex { return "codex" }
    if claudeCLI { return "claudecli" }
    return "claude"
}

/// 0…1 loudness from a raw RMS sample, on a dB curve so quiet speech still moves the bars.
func micLevel(rms: Float) -> CGFloat {
    let db = 20 * log10(max(rms, 1e-7))
    return CGFloat(max(0, min(1, (db + 50) / 50)))
}

@MainActor
final class AppState: ObservableObject {
    @Published var isListening = false
    @Published var partial = ""           // live transcript while listening
    @Published var isThinking = false
    @Published var showNext = false
    @Published var container: CGRect?     // normalized top-left-origin focus area
    @Published var reply = ""             // last thing Debby said (also spoken aloud)
    @Published var agentLine = ""         // newest line of background-agent output
    @Published var agentBusy = false
    @Published var hovering = false       // cursor is on the notch
    @Published var levels = [CGFloat](repeating: 0, count: 28)
    @Published var isSpeaking = false     // TTS is active; pill shown near cursor
    @Published var speakingText = ""      // rolling window of words being spoken
    @Published var isDrawing = false      // screen-drawing mode active

    /// The notch opens on hover, and whenever there's something to show.
    var notchExpanded: Bool {
        hovering || isListening || isThinking || showNext || agentBusy || !reply.isEmpty
    }

    weak var notch: NotchWindow?
    let speech = SpeechInput()
    let voice = SpeechOutput()
    let overlay = OverlayController()
    let containerOutline = ContainerOutline()
    let pointer = DebbyPointer()
    let drawingController = DrawingController()
    private var history: [(role: String, text: String)] = []
    private var chatGeneration = 0
    /// Steps drawn without the user asking. Capped: a model that never stops saying MORE would
    /// otherwise loop on the API forever.
    private var autoSteps = 0
    private let maxAutoSteps = 12
    private var clickMonitor: Any?
    private var pendingAdvance: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var activeScreen: NSScreen?
    private var runningAgents: [Process] = []
    private var lessonPlayer: LessonPlayer?
    /// Raw stream text as far as it got, so a lesson that dies mid-flight can still tell
    /// history what it already drew.
    private var partialReply = ""

    init() {
        overlay.onHide = { [weak self] in
            self?.pointer.endHighlight()
            self?.showNext = false
            self?.disarmClickWatch()
        }
        voice.onSpeakStart = { [weak self] text in
            Task { @MainActor in
                self?.isSpeaking = true
                self?.speakingText = text
            }
        }
        voice.onWord = { [weak self] text in
            Task { @MainActor in self?.speakingText = text }
        }
        voice.onSpeakEnd = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
                self?.speakingText = ""
                self?.lessonPlayer?.speechFinished()
            }
        }
        drawingController.onStop = { [weak self] in
            Task { @MainActor in self?.isDrawing = false }
        }
    }

    var apiKey: String {
        let stored = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        return stored.isEmpty ? (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "") : stored
    }
    var model: String {
        let m = UserDefaults.standard.string(forKey: "model") ?? ""
        return m.isEmpty ? "claude-sonnet-5" : m
    }
    var voiceReplies: Bool {
        UserDefaults.standard.object(forKey: "voiceReplies") == nil ? true : UserDefaults.standard.bool(forKey: "voiceReplies")
    }
    var agentFullAccess: Bool { UserDefaults.standard.bool(forKey: "agentFullAccess") }
    var backend: String { resolveBackend(UserDefaults.standard.string(forKey: "backend") ?? "") }

    /// Agents exist mostly to touch your apps, and `codex exec` auto-denies every
    /// Composio write ("user cancelled MCP tool call") — so agents use claude when
    /// it's available, whatever brain answers the chat.
    var agentBackend: String { Claude.CLI.isLoggedIn ? "claude" : "codex" }
    var codexModel: String {
        let m = UserDefaults.standard.string(forKey: "codexModel") ?? ""
        return m.isEmpty ? Codex.defaultModel : m
    }
    /// Same order All-In-One-AI uses (`gemini_api_key()`), so one exported key feeds both.
    var geminiApiKey: String {
        let stored = UserDefaults.standard.string(forKey: "geminiApiKey") ?? ""
        guard stored.isEmpty else { return stored }
        let env = ProcessInfo.processInfo.environment
        return env["GOOGLE_API_KEY"] ?? env["GEMINI_API_KEY"] ?? ""
    }
    var geminiModel: String {
        let m = UserDefaults.standard.string(forKey: "geminiModel") ?? ""
        return m.isEmpty ? Gemini.defaultModel : m
    }
    var openaiApiKey: String {
        let stored = UserDefaults.standard.string(forKey: "openaiApiKey") ?? ""
        return stored.isEmpty ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "") : stored
    }
    var openaiModel: String {
        let m = UserDefaults.standard.string(forKey: "openaiModel") ?? ""
        return m.isEmpty ? OpenAI.defaultModel : m
    }

    // MARK: - Notch

    /// Polled from the pointer's frame timer: cheaper and more reliable than tracking
    /// areas, since a non-activating panel in a background app barely gets mouse events.
    /// The notch is click-through unless the cursor is actually on it.
    func trackMouse(_ p: CGPoint) {
        let screen = NSScreen.notchHost
        let hit = notchRect(screen: screen.frame, collapsed: screen.collapsedNotch, expanded: notchExpanded)
        let inside = hit.insetBy(dx: -4, dy: -4).contains(p)
        guard inside != hovering else { return }
        hovering = inside
        notch?.ignoresMouseEvents = !inside
    }

    /// Show a line in the notch; it fades so the notch closes itself again.
    private func show(_ text: String) {
        reply = text
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reply = ""
        }
    }

    /// ✕ / status-item stop: end the session — cancel everything visibly and invisibly in flight.
    func dismiss() {
        chatGeneration += 1
        pendingAdvance?.cancel()
        pendingAdvance = nil
        fadeTask?.cancel()
        if isListening { _ = speech.stop(); isListening = false; partial = "" }
        voice.stop()
        lessonPlayer?.cancel()
        lessonPlayer = nil
        disarmClickWatch()
        overlay.hide()
        RegionSelector.close()
        clearContainer()
        showNext = false
        isThinking = false
        isSpeaking = false
        speakingText = ""
        reply = ""
        agentLine = ""
        if isDrawing { isDrawing = false; drawingController.stop() }
    }

    func newChat() {
        chatGeneration += 1
        pendingAdvance?.cancel()
        pendingAdvance = nil
        disarmClickWatch()
        RegionSelector.close()
        runningAgents.forEach { $0.terminate() }
        runningAgents.removeAll()
        agentBusy = false
        agentLine = ""
        history.removeAll()
        partial = ""
        reply = ""
        showNext = false
        isThinking = false
        overlay.hide()
        voice.stop()
        lessonPlayer?.cancel()
        lessonPlayer = nil
    }

    func toggleDrawing() {
        // Use drawingController.isActive as source of truth — AppState.isDrawing may lag
        // by one run-loop tick after the "Done" button fires stop() asynchronously.
        if drawingController.isActive {
            isDrawing = false
            drawingController.stop()
        } else {
            isDrawing = true
            drawingController.start(on: activeScreen ?? NSScreen.underMouse)
        }
    }

    private func colorFrom(_ name: String) -> Color {
        switch name.lowercased() {
        case "red":    return .red
        case "blue":   return .blue
        case "green":  return .green
        case "yellow": return .yellow
        case "white":  return .white
        case "purple": return .purple
        default:       return .orange
        }
    }

    func beginContainerSelection() {
        overlay.hide()
        let screen = activeScreen ?? NSScreen.underMouse
        activeScreen = screen
        RegionSelector.begin(on: screen) { [weak self] rect in
            guard let self, let rect else { return }
            self.container = rect
            self.containerOutline.show(rect, on: screen)
        }
    }

    func clearContainer() {
        container = nil
        containerOutline.hide()
    }

    // Walkthrough auto-advance: after Debby points somewhere, the user's next click
    // (in any other app — clicks on our own notch don't reach the global monitor)
    // triggers a fresh screenshot so Debby can check the new screen and give the next step.
    private func armClickWatch() {
        disarmClickWatch()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.clickDetected() }
        }
    }

    private func disarmClickWatch() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func clickDetected() {
        guard !isListening else { return }  // mid-dictation click must not destroy the transcript
        disarmClickWatch()
        overlay.hide()
        showNext = false  // no double-advance via the chip while we wait
        let gen = chatGeneration
        pendingAdvance = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }  // let menus/pages settle
            guard let self, self.chatGeneration == gen else { return }
            self.submit("I clicked. Check the screen — what's next?")
        }
    }

    // MARK: - Talking

    /// ⌃⌥: hold to talk (release sends), quick-tap to latch on (silence sends).
    func talkChord(down: Bool, heldFor: TimeInterval) {
        if down {
            if isListening { stopListeningAndSend() } else { startListening() }
        } else if heldFor >= 0.35 {
            stopListeningAndSend()
        }
    }

    func toggleListening() {
        if isListening { stopListeningAndSend() } else { startListening() }
    }

    func startListening() {
        voice.stop()
        lessonPlayer?.cancel()
        lessonPlayer = nil
        pendingAdvance?.cancel()  // talking over the lesson stops it advancing
        activeScreen = NSScreen.underMouse
        partial = ""
        reply = ""
        levels = [CGFloat](repeating: 0, count: levels.count)
        isListening = true
        speech.start(
            onPartial: { [weak self] t in Task { @MainActor in self?.partial = t } },
            onFinal: { [weak self] t in Task { @MainActor in self?.finishListening(with: t) } },
            onLevel: { [weak self] l in Task { @MainActor in
                guard let self, self.isListening else { return }
                self.levels.removeFirst()
                self.levels.append(micLevel(rms: l))
            } },
            onError: { [weak self] msg in Task { @MainActor in
                guard let self else { return }
                self.isListening = false
                self.partial = ""
                self.show("🎤 \(msg)")
            } }
        )
    }

    func stopListeningAndSend() {
        guard isListening else { return }
        let text = speech.stop()
        isListening = false
        partial = ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { submit(t) }
    }

    private func finishListening(with text: String) {
        guard isListening else { return }
        isListening = false
        partial = ""
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { submit(t) }
    }

    func submit(_ text: String, auto: Bool = false) {
        chatGeneration += 1   // newest request wins; a stale reply must not install a player
        if isListening { _ = speech.stop(); isListening = false; partial = "" }
        voice.stop()
        lessonPlayer?.cancel()
        lessonPlayer = nil
        disarmClickWatch()
        pendingAdvance?.cancel()  // manual send supersedes a queued auto-advance
        showNext = false
        if !auto { autoSteps = 0 }   // a new question starts a new lesson budget
        if let task = agentTask(from: text) {
            runAgent(task)
        } else {
            talk(text, withShot: !auto)
        }
    }

    private func talk(_ text: String, withShot: Bool = true) {
        // `backend` re-reads UserDefaults on every access and @AppStorage writes land at once,
        // so switching the Brain picker mid-request would otherwise change the answer between
        // the switch below and the playback guard — replaying a streamed lesson, or dropping a
        // finished reply. One read, one brain, for the whole turn.
        let brain = backend
        if brain == "claude" && apiKey.isEmpty {
            show("I need an Anthropic API key — open ⚙︎ in the notch and paste one (or switch the brain to Codex, or set ANTHROPIC_API_KEY).")
            return
        }
        if brain == "gemini" && geminiApiKey.isEmpty {
            show("I need a Google AI API key — open ⚙︎ in the notch and paste one (or set GOOGLE_API_KEY).")
            return
        }
        if brain == "openai" && openaiApiKey.isEmpty {
            show("I need an OpenAI API key — open ⚙︎ in the notch and paste one (or set OPENAI_API_KEY).")
            return
        }
        partialReply = ""
        isThinking = true
        let gen = chatGeneration
        // Snapshot: the same container/screen must be used for crop AND mapping,
        // even if the user changes them during the multi-second request.
        let snapContainer = container
        let screen = activeScreen ?? NSScreen.underMouse
        // The prompt quotes this so the model can make squares square and turns perpendicular.
        debbyScreenAspect = screen.frame.width / max(1, screen.frame.height)
        Task {
            do {
                // An auto-advance step changes nothing on screen except our own drawing,
                // and the screenshot excludes our windows — so there is nothing new to see.
                let shot = withShot
                    ? try await Capture.screen(excludingSelf: true, cropTo: snapContainer,
                                               displayID: screen.displayID)
                    : Capture.Shot(base64: "", filePath: "")
                let reply: String
                switch brain {
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
                    // The lesson has already played by the time this returns; only the
                    // raw text comes back, for history.
                    reply = try await streamLesson(gen: gen, container: snapContainer,
                                                   screen: screen, text: text,
                                                   imageB64: shot.base64)
                default:
                    reply = try await Claude.send(apiKey: apiKey, model: model, history: history,
                                                  userText: text, imageB64: shot.base64)
                }
                // The HTTP backends logged nothing at all, so "it didn't draw" was undebuggable:
                // no reply, no parse result, no way to tell a refusal from a dropped DRAWINGS line.
                DebbyLog.write("CHAT \(brain) reply:\n\(reply)")
                // Parsed for both paths: the streamed brain plays from the same BeatSplitter,
                // which the self-check proves chunk-invariant, so these counts are what really
                // played — and it's the brain that most needs field debugging.
                let parsed = parseReply(reply)
                let (clean, anns, drawings) = (parsed.text, parsed.annotations, parsed.drawings)
                DebbyLog.write("PARSED annotations=\(anns.count) drawings=\(drawings.count) more=\(parsed.more)")
                guard gen == chatGeneration else { return }  // user hit New / ✕ meanwhile
                isThinking = false
                history.append((role: "user", text: text))
                // Keep the DRAWINGS block in history, not the spoken text alone. The screenshot
                // excludes our own windows, so the canvas is invisible to the model next turn —
                // these coordinates are the ONLY record of what it already drew, and without
                // them step 2 of a diagram can't meet step 1. Streamed or not, it's the raw text.
                history.append((role: "assistant", text: reply))
                if history.count > 20 { history.removeFirst(history.count - 20) }
                // The streamed brain already played this lesson while it arrived; parsing and
                // playing it a second time here would say every sentence twice.
                if brain != "openai" {
                    show(clean)
                    // Snapshot once: voiceReplies can change mid-lesson, and a player built for
                    // speech must not have onSay start reading a live flag that later says "off"
                    // with no callback ever coming to un-stick it.
                    let speechOn = voiceReplies
                    let player = LessonPlayer(speechEnabled: speechOn)
                    lessonPlayer = player
                    if !parsed.annotations.isEmpty { overlay.showEmpty(on: screen) }
                    attach(player, gen: gen, container: snapContainer, screen: screen,
                           speechOn: speechOn, more: { parsed.more })
                    player.append(parsed.beats)
                    player.closeStream()
                }
            } catch {
                guard gen == chatGeneration else { return }
                isThinking = false
                DebbyLog.write("CHAT ERROR (\(brain)) \(error.localizedDescription)")
                // A half-played lesson would keep narrating over the error: every onSay writes
                // the notch, so the ⚠️ would be gone within a sentence. Stop it first.
                lessonPlayer?.cancel()
                lessonPlayer = nil
                // Shapes are already on screen and those DRAW: coordinates are the only record
                // of them, so a stream that died mid-lesson still has to reach history — else
                // the next turn draws step 2 somewhere step 1 never was. Both turns or neither:
                // Claude.send maps history straight into `messages`, and a dangling user turn
                // there is two user messages in a row, which the API rejects.
                if !partialReply.isEmpty {
                    history.append((role: "user", text: text))
                    history.append((role: "assistant", text: partialReply))
                    if history.count > 20 { history.removeFirst(history.count - 20) }
                }
                show("⚠️ \(error.localizedDescription)")
            }
        }
    }

    /// Streams a reply straight into a player, returning the raw text for history.
    /// The splitter is a local `var` captured by the delta closure — legal, and simpler
    /// than threading it back out through an `inout` parameter.
    private func streamLesson(gen: Int, container: CGRect?, screen: NSScreen,
                              text: String, imageB64: String) async throws -> String {
        // Same snapshot the whole-reply path takes, for the same reason: onSay must never
        // read a live voiceReplies that can flip to "off" mid-lesson and leave the player
        // waiting for a speech callback that will never come.
        let speechOn = voiceReplies
        let player = LessonPlayer(speechEnabled: speechOn)
        // The whole-reply path only installs its player behind this same check; without it,
        // turn A's capture can return (and get this far) after turn B already installed B's
        // player — A would overwrite it, leaving B silent and undrawn. `talk`'s catch guards
        // on `gen == chatGeneration` first, so this throw is a silent no-op for a normal
        // supersede, never a user-visible error.
        guard gen == chatGeneration else { throw CancellationError() }
        lessonPlayer = player
        var sp = BeatSplitter()
        // `more` reads the splitter from onIdle, which cannot fire before closeStream()
        // below — so by the time it runs, the last feed() is long finished.
        attach(player, gen: gen, container: container, screen: screen,
               speechOn: speechOn, more: { sp.more })
        // No parsed `clean` text exists up front, so the notch follows the narration instead
        // of preceding it. Wrapping is how the one and only voice.speak call site stays
        // inside attach. Accumulating rather than replacing because the notch hides `reply`
        // while she's speaking: replaced, the answer left behind afterwards — and the whole
        // answer with voiceReplies off — would be its last sentence alone.
        let base = player.onSay
        var spoken = ""
        player.onSay = { [weak self] s in
            guard let self, self.chatGeneration == gen else { return }
            spoken += spoken.isEmpty ? s : " " + s
            self.show(spoken)
            base?(s)
        }

        var raw = ""
        try await OpenAI.stream(apiKey: openaiApiKey, model: openaiModel, history: history,
                                userText: text, imageB64: imageB64) { [weak self] chunk in
            raw += chunk
            let beats = sp.feed(chunk)
            guard !beats.isEmpty else { return }
            // Copy on this thread: `raw` keeps growing here, and reading it from the hop
            // below would be a read racing an append.
            let soFar = raw
            // onDelta lands on a URLSession queue; the player and every @Published flag are
            // main-only. DispatchQueue.main, not Task {}, because the hop has to preserve
            // order — the main queue guarantees FIFO, unstructured tasks do not, and beats
            // that arrive out of order are a shape drawn before the sentence that explains it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Identity, not just generation: cancel() empties the queue but leaves the
                    // player willing to work, this closure holds it strongly, and
                    // startListening() is the one cancel path that does NOT bump the
                    // generation. Without the `===` an interrupted lesson resurrects — shapes
                    // drawn, click-watch armed, and a fresh sentence spoken straight into the
                    // microphone that is now recording the user.
                    guard let self, self.lessonPlayer === player,
                          self.chatGeneration == gen else { return }
                    self.isThinking = false  // she's already talking; stop saying "thinking"
                    self.partialReply = soFar
                    player.append(beats)
                }
            }
        }
        // Resumes on the main actor behind every hop above — same queue, still in order.
        let tail = sp.finish()
        guard lessonPlayer === player, chatGeneration == gen else { return raw }
        if !tail.isEmpty { player.append(tail) }
        player.closeStream()
        return raw
    }

    /// Wires a player to the screen and the voice. `more` is a closure rather than a Bool
    /// because a streamed reply only knows whether the lesson continues once the stream
    /// has closed — which is before `onIdle` fires, but after this is called.
    private func attach(_ player: LessonPlayer, gen: Int, container: CGRect?,
                        screen: NSScreen, speechOn: Bool, more: @escaping () -> Bool) {
        player.onSay = { [weak self] sentence in
            guard let self, self.chatGeneration == gen else { return }
            if speechOn { self.voice.speak(sentence) }
        }
        player.onPoint = { [weak self] ann in
            guard let self, self.chatGeneration == gen else { return }
            let m = mapToScreen(ann, container: container)
            let f = screen.frame
            let cx = m.x + (m.w ?? 0) / 2, cy = m.y + (m.h ?? 0) / 2
            self.pointer.highlight([CGPoint(x: f.minX + cx * f.width,
                                            y: f.minY + (1 - cy) * f.height)])
            // The whole-reply path pre-opens the window because it counted the annotations
            // first; a streamed one only finds out here, and addAnnotation alone paints
            // into a window that was never shown.
            if !self.overlay.isOpen { self.overlay.showEmpty(on: screen) }
            self.overlay.addAnnotation(m)
            self.showNext = true
            self.armClickWatch()
        }
        player.onDraw = { [weak self] spec in
            guard let self, self.chatGeneration == gen,
                  let shape = self.drawnShape(from: spec, container: container,
                                              screen: screen) else { return }
            self.isDrawing = true
            // Non-interactive: the AI illustrating something must not take over the
            // cursor and hand the user a drawing toolbar.
            if !self.drawingController.isActive {
                self.drawingController.start(on: screen, interactive: false)
            }
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

    /// Normalized ShapeSpec → on-screen DrawnShape. A text label is one point;
    /// everything else needs a start and an end.
    private func drawnShape(from spec: ShapeSpec, container: CGRect?,
                            screen: NSScreen) -> DrawnShape? {
        guard let tool = DrawTool(rawValue: spec.tool) else {
            DebbyLog.write("DRAW rejected: unknown tool \(spec.tool)")
            return nil
        }
        guard spec.points.count >= (tool == .text ? 1 : 2) else {
            DebbyLog.write("DRAW rejected: \(spec.tool) needs more points, got \(spec.points.count)")
            return nil
        }
        let pts = spec.points.map { pt -> CGPoint in
            let mapped = mapToScreen(Annotation(x: pt.x, y: pt.y, label: ""), container: container)
            return CGPoint(x: mapped.x * screen.frame.width, y: mapped.y * screen.frame.height)
        }
        return DrawnShape(tool: tool, points: pts,
                          color: colorFrom(spec.color ?? "orange"),
                          lineWidth: CGFloat(spec.lineWidth ?? 3),
                          label: spec.label ?? "")
    }

    private func runAgent(_ task: String) {
        agentBusy = true
        agentLine = "🤖 \(task)"
        let displayID = (activeScreen ?? NSScreen.underMouse).displayID
        Task {
            let shotPath = (try? await Capture.screen(excludingSelf: true, displayID: displayID))?.filePath
            var procRef: Process?
            procRef = AgentRunner.run(
                backend: agentBackend, task: task, screenshotPath: shotPath, fullAccess: agentFullAccess,
                onOutput: { [weak self] chunk in Task { @MainActor in self?.agentTick(chunk) } },
                onDone: { [weak self] code in Task { @MainActor in
                    guard let self else { return }
                    self.agentBusy = false
                    self.agentLine = code == 0 ? "✅ agent done" : "❌ agent exited (\(code))"
                    if let p = procRef { self.runningAgents.removeAll { $0 === p } }
                    self.agentFade()
                } }
            )
            if let p = procRef { runningAgents.append(p) }
        }
    }

    /// The notch is a ticker, not a terminal: only the newest line of agent output shows.
    private func agentTick(_ chunk: String) {
        guard let last = chunk.split(whereSeparator: \.isNewline).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return }
        agentLine = String(last.prefix(120))
    }

    private func agentFade() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self, !self.agentBusy else { return }
            self.agentLine = ""
        }
    }
}

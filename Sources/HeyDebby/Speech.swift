@preconcurrency import AVFoundation
import Speech

/// Loudness of one mic buffer, for the cursor visualiser.
func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    let n = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<n { sum += ch[i] * ch[i] }
    return (sum / Float(n)).squareRoot()
}

@MainActor
final class SpeechInput {
    private let engine = AVAudioEngine()
    private let secretStore: SecretStoring
    private var session: (any TranscriptionSession)?
    private var latest = ""
    private var silenceTimer: Timer?
    private var generation = 0
    private var tapInstalled = false
    private var finalizeWhenReady = false
    private var finalHandler: ((String) -> Void)?
    private var errorHandler: ((String) -> Void)?

    init(secretStore: SecretStoring = SecretStore.shared) {
        self.secretStore = secretStore
    }

    func start(onPartial: @escaping (String) -> Void,
               onFinal: @escaping (String) -> Void,
               onLevel: @escaping (Float) -> Void,
               onError: @escaping (String) -> Void) {
        cancel()
        generation += 1
        let currentGeneration = generation
        latest = ""
        finalHandler = onFinal
        errorHandler = onError
        Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.requestMicrophoneAccess() else {
                    throw AppleSpeechTranscriptionProviderError(message: "Microphone permission is required.")
                }
                let selection = self.providerSelection()
                let activeSession: any TranscriptionSession
                do {
                    activeSession = try await self.startSession(
                        provider: selection.provider,
                        generation: currentGeneration,
                        onPartial: onPartial
                    )
                } catch {
                    guard selection.canFallBackToApple else { throw error }
                    activeSession = try await self.startSession(
                        provider: AppleSpeechTranscriptionProvider(),
                        generation: currentGeneration,
                        onPartial: onPartial
                    )
                }
                guard self.generation == currentGeneration else {
                    activeSession.cancel()
                    return
                }
                self.session = activeSession
                let input = self.engine.inputNode
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024,
                                 format: input.outputFormat(forBus: 0)) { buffer, _ in
                    activeSession.append(buffer)
                    let level = rms(buffer)
                    DispatchQueue.main.async { onLevel(level) }
                }
                self.tapInstalled = true
                self.engine.prepare()
                try self.engine.start()
                if self.finalizeWhenReady { self.finalize() }
            } catch {
                guard self.generation == currentGeneration else { return }
                self.finishWithError(error.localizedDescription)
            }
        }
    }

    func finalize() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopAudio()
        guard let session else {
            finalizeWhenReady = true
            return
        }
        finalizeWhenReady = false
        session.finalize()
    }

    func cancel() {
        generation += 1
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopAudio()
        session?.cancel()
        session = nil
        latest = ""
        finalizeWhenReady = false
        finalHandler = nil
        errorHandler = nil
    }

    func stop() -> String {
        let text = latest
        cancel()
        return text
    }

    private func startSession(provider: any TranscriptionProvider, generation: Int,
                              onPartial: @escaping (String) -> Void) async throws
        -> any TranscriptionSession {
        if provider.metadata.requiresSpeechRecognitionPermission {
            guard await requestSpeechRecognitionAccess() else {
                throw AppleSpeechTranscriptionProviderError(
                    message: "Speech recognition permission is required."
                )
            }
        }
        return try await provider.startSession(
            contextualKeyterms: ["HeyDebby", "Google Slides", "Google Sheets"],
            onPartial: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.latest = text
                    onPartial(text)
                    self.bumpSilenceTimer()
                }
            },
            onFinal: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.finish(with: text)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.finishWithError(error.localizedDescription)
                }
            }
        )
    }

    private func providerSelection() -> (provider: any TranscriptionProvider, canFallBackToApple: Bool) {
        let preference = UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "auto"
        let key = ((try? secretStore.value(for: .assemblyAI)) ?? nil)
            ?? ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"]
        if preference == "assemblyai" {
            return (AssemblyAITranscriptionProvider(apiKey: key ?? ""), false)
        }
        if preference == "auto", let key, !key.isEmpty {
            return (AssemblyAITranscriptionProvider(apiKey: key), true)
        }
        return (AppleSpeechTranscriptionProvider(), false)
    }

    private func bumpSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) {
            [weak self] _ in Task { @MainActor in self?.finalize() }
        }
    }

    private func finish(with text: String) {
        let handler = finalHandler
        stopAudio()
        session = nil
        latest = ""
        finalizeWhenReady = false
        finalHandler = nil
        errorHandler = nil
        handler?(text)
    }

    private func finishWithError(_ message: String) {
        let handler = errorHandler
        stopAudio()
        session?.cancel()
        session = nil
        latest = ""
        finalizeWhenReady = false
        finalHandler = nil
        errorHandler = nil
        handler?(message.isEmpty ? "Listening stopped — tap the mic to try again." : message)
    }

    private func stopAudio() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func requestSpeechRecognitionAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization {
                    continuation.resume(returning: $0 == .authorized)
                }
            }
        default: return false
        }
    }
}

final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    /// Called on main thread when speech starts with full text.
    var onSpeakStart: ((String) -> Void)?
    /// Called on main thread with a rolling window of text as each word is spoken.
    var onWord: ((String) -> Void)?
    /// Called on main thread when speech finishes or is cancelled.
    var onSpeakEnd: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    // ElevenLabs path: an MP3 arrives whole and plays through AVAudioPlayer. `speakGen`
    // is the identity guard (like currentUtterance ===): a fetch that returns after a
    // stop()/new speak() must not start playing over the top of what replaced it.
    private var player: AVAudioPlayer?
    private var ttsTask: Task<Void, Never>?
    private var speakGen = 0

    /// Settings, or an ELEVENLABS_API_KEY env fallback. Empty means use the native voice.
    static func elevenKey() -> String {
        let stored = UserDefaults.standard.string(forKey: "elevenApiKey") ?? ""
        return stored.isEmpty ? (ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "") : stored
    }

    /// Real English voices, best first — novelty and legacy robo-voices excluded.
    static func candidateVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { !$0.identifier.contains("eloquence") && !$0.identifier.contains("speech.synthesis.voice") }
            .sorted { rank($0) > rank($1) }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        let quality = v.quality == .premium ? 100 : v.quality == .enhanced ? 50 : 0
        return quality + (v.language == "en-US" ? 10 : 0)
    }

    /// Speak `text`. Routes to ElevenLabs when the engine is set to it and a key exists,
    /// otherwise the native synthesiser. Either way `onSpeakStart`/`onSpeakEnd` fire exactly
    /// once, so the LessonPlayer that waits on the end callback behaves identically.
    func speak(_ text: String) {
        stop()
        guard !text.isEmpty else { return }
        // ElevenLabs is the default engine — but a missing key falls straight through to
        // the native voice, so Debby still speaks out of the box, before any key is pasted.
        let engine = UserDefaults.standard.string(forKey: "voiceEngine") ?? "eleven"
        let key = Self.elevenKey()
        if engine == "eleven", !key.isEmpty { speakEleven(text, apiKey: key) }
        else { speakSystem(text) }
    }

    private func speakSystem(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        let chosenId = UserDefaults.standard.string(forKey: "voiceId") ?? ""
        utt.voice = (chosenId.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: chosenId))
            ?? Self.candidateVoices().first
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utt.rate = 0.52
        utt.pitchMultiplier = 1.02
        currentUtterance = utt
        synth.delegate = self
        synth.speak(utt)
        onSpeakStart?(text)
    }

    private func speakEleven(_ text: String, apiKey: String) {
        speakGen += 1
        let gen = speakGen
        onSpeakStart?(text)
        let voiceID = UserDefaults.standard.string(forKey: "elevenVoiceId") ?? ""
        let model = UserDefaults.standard.string(forKey: "elevenModel") ?? ""
        ttsTask = Task { [weak self] in
            do {
                let data = try await Eleven.tts(apiKey: apiKey, voiceID: voiceID, model: model, text: text)
                if Task.isCancelled { return }
                DispatchQueue.main.async { [weak self] in self?.playEleven(data, gen: gen, fallback: text) }
            } catch {
                // A bad key, an unknown voice, or a dropped connection must not leave Debby
                // mute — fall back to the native voice so the reply is still spoken and the
                // lesson still advances.
                DebbyLog.write("ELEVEN tts failed: \(error.localizedDescription) — native voice")
                if Task.isCancelled { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.speakGen == gen else { return }
                    self.speakSystem(text)
                }
            }
        }
    }

    private func playEleven(_ data: Data, gen: Int, fallback: String) {
        guard speakGen == gen else { return }   // superseded while the MP3 was in flight
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
        } catch {
            DebbyLog.write("ELEVEN play failed: \(error.localizedDescription) — native voice")
            speakSystem(fallback)
        }
    }

    /// Async so it never re-enters the LessonPlayer pump from inside speak()'s own stop().
    private func fireSpeakEnd() {
        DispatchQueue.main.async { [weak self] in self?.onSpeakEnd?() }
    }

    func stop() {
        // ElevenLabs: cancel any in-flight fetch and stop playback. Bump the generation so a
        // fetch that lands after this is ignored. Fire the end callback only if something was
        // actually playing, matching the synth's didCancel behaviour.
        speakGen += 1
        ttsTask?.cancel()
        ttsTask = nil
        if let p = player {
            p.stop()
            player = nil
            fireSpeakEnd()
        }
        synth.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        let nsText = utterance.speechString as NSString
        let endChar = min(characterRange.upperBound, nsText.length)
        let windowStart = max(0, endChar - 80)
        var chunk = nsText.substring(with: NSRange(location: windowStart, length: endChar - windowStart))
        // Trim to a word boundary at the start when the window has slid forward.
        if windowStart > 0, let spaceIdx = chunk.firstIndex(of: " ") {
            chunk = String(chunk[chunk.index(after: spaceIdx)...])
        }
        let display = chunk.trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.async { [weak self] in self?.onWord?(display) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        DispatchQueue.main.async { [weak self] in self?.onSpeakEnd?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        DispatchQueue.main.async { [weak self] in self?.onSpeakEnd?() }
    }

    // MARK: - AVAudioPlayerDelegate (ElevenLabs playback)

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        guard p === player else { return }   // a stop() already retired this one
        player = nil
        fireSpeakEnd()
    }
}

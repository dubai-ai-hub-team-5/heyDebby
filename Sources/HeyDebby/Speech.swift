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

final class SpeechInput {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var silenceTimer: Timer?

    func start(onPartial: @escaping (String) -> Void,
               onFinal: @escaping (String) -> Void,
               onLevel: @escaping (Float) -> Void,
               onError: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    onError("Speech recognition not authorized (System Settings → Privacy & Security)")
                    return
                }
                self?.begin(onPartial: onPartial, onFinal: onFinal, onLevel: onLevel, onError: onError)
            }
        }
    }

    private func begin(onPartial: @escaping (String) -> Void,
                       onFinal: @escaping (String) -> Void,
                       onLevel: @escaping (Float) -> Void,
                       onError: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            onError("Speech recognizer unavailable")
            return
        }
        latest = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
            let level = rms(buffer)
            DispatchQueue.main.async { onLevel(level) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            onError("Mic error: \(error.localizedDescription)")
            return
        }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                onPartial(self.latest)
                DispatchQueue.main.async { self.bumpSilenceTimer(onFinal: onFinal) }
            }
            if error != nil {
                DispatchQueue.main.async {
                    guard self.task != nil else { return }  // normal stop/cancel already tore down
                    self.teardown()
                    onError("Listening stopped — tap the mic to try again.")
                }
            }
        }
    }

    // Auto-send after 1.6s of silence following speech.
    private func bumpSilenceTimer(onFinal: @escaping (String) -> Void) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            let text = self.latest
            self.teardown()
            onFinal(text)
        }
    }

    /// Manual stop; returns whatever was transcribed.
    func stop() -> String {
        let text = latest
        teardown()
        return text
    }

    private func teardown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        latest = ""
    }
}

final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    /// Called on main thread when speech starts with full text.
    var onSpeakStart: ((String) -> Void)?
    /// Called on main thread with a rolling window of text as each word is spoken.
    var onWord: ((String) -> Void)?
    /// Called on main thread when speech finishes or is cancelled.
    var onSpeakEnd: (() -> Void)?

    /// Flash, not multilingual_v2: this is a voice assistant answering out loud, so time
    /// to first audio beats fidelity. Flash v2.5 is ~75ms; multilingual_v2 is seconds.
    /// Same pair the original Clicky ships (worker/wrangler.toml + ElevenLabsTTSClient).
    static let defaultElevenLabsModel = "eleven_flash_v2_5"
    static let defaultElevenLabsVoice = "kPzsL2i3teMYv0FxEYQ6" // Brittney

    private let synth = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var player: AVAudioPlayer?
    private var wordTimer: Timer?
    private var activeText = ""
    private var audioFile: URL?
    private var audioRequestID: UUID?
    private var currentRequestID: UUID?
    private var elevenTask: Task<Void, Never>?

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

    func speak(_ text: String) {
        stop()
        guard !text.isEmpty else { return }
        let source = UserDefaults.standard.string(forKey: "voiceSource") ?? ""
        let key = elevenLabsAPIKey()
        if source == "elevenlabs" && !key.isEmpty {
            let requestID = UUID()
            currentRequestID = requestID
            speakElevenLabs(text, apiKey: key, requestID: requestID)
        } else {
            if source == "elevenlabs" {
                DebbyLog.write("ElevenLabs selected but no API key; falling back to native TTS")
            }
            currentRequestID = nil
            speakNative(text)
        }
    }

    func stop() {
        elevenTask?.cancel()
        elevenTask = nil
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player?.delegate = nil
        player = nil
        wordTimer?.invalidate()
        wordTimer = nil
        activeText = ""
        currentUtterance = nil
        currentRequestID = nil
        audioRequestID = nil
        if let f = audioFile {
            try? FileManager.default.removeItem(at: f)
            audioFile = nil
        }
    }

    // MARK: - Native TTS

    private func speakNative(_ text: String) {
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

    // MARK: - ElevenLabs TTS

    private func elevenLabsAPIKey() -> String {
        let stored = UserDefaults.standard.string(forKey: "elevenlabsApiKey") ?? ""
        if !stored.isEmpty { return stored }
        let env = ProcessInfo.processInfo.environment
        return env["ELEVENLABS_API_KEY"] ?? env["ELEVEN_API_KEY"] ?? ""
    }

    private func effectiveElevenLabsVoice() -> String {
        let stored = UserDefaults.standard.string(forKey: "elevenlabsVoiceId") ?? ""
        return stored.isEmpty ? Self.defaultElevenLabsVoice : stored
    }

    private func effectiveElevenLabsModel() -> String {
        let stored = UserDefaults.standard.string(forKey: "elevenlabsModel") ?? ""
        return stored.isEmpty ? Self.defaultElevenLabsModel : stored
    }

    private func speakElevenLabs(_ text: String, apiKey: String, requestID: UUID) {
        activeText = text

        let voiceId = effectiveElevenLabsVoice()
        let model = effectiveElevenLabsModel()
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            DebbyLog.write("ElevenLabs bad voice id: \(voiceId)")
            speakNative(text)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DebbyLog.write("ElevenLabs request build failed: \(error.localizedDescription)")
            speakNative(text)
            return
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        audioFile = file
        elevenTask = Task { [weak self] in
            guard let self = self else { return }
            let capturedID = requestID
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else {
                    let detail = String(data: data, encoding: .utf8) ?? "no body"
                    DebbyLog.write("ElevenLabs API error \(status): \(detail)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.currentRequestID == capturedID else { return }
                        self.audioFile = nil
                        self.speakNative(text)
                    }
                    return
                }
                try data.write(to: file, options: .atomic)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentRequestID == capturedID else {
                        try? FileManager.default.removeItem(at: file)
                        return
                    }
                    self.playAudioFile(file, text: text, requestID: capturedID)
                }
            } catch let err as URLError where err.code == .cancelled {
                try? FileManager.default.removeItem(at: file)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: file)
            } catch {
                DebbyLog.write("ElevenLabs request failed: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentRequestID == capturedID else { return }
                    self.audioFile = nil
                    self.speakNative(text)
                }
            }
        }
    }

    private func playAudioFile(_ url: URL, text: String, requestID: UUID) {
        guard currentRequestID == requestID else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            audioFile = url
            audioRequestID = requestID
            activeText = text
            guard p.play() else {
                DebbyLog.write("ElevenLabs audio player refused to start")
                player?.delegate = nil
                player = nil
                audioRequestID = nil
                try? FileManager.default.removeItem(at: url)
                audioFile = nil
                speakNative(text)
                return
            }
            onSpeakStart?(text)
            startWordTimer(text: text)
        } catch {
            DebbyLog.write("ElevenLabs audio playback failed: \(error.localizedDescription)")
            player?.delegate = nil
            player = nil
            audioRequestID = nil
            try? FileManager.default.removeItem(at: url)
            audioFile = nil
            speakNative(text)
        }
    }

    private func startWordTimer(text: String) {
        wordTimer?.invalidate()
        guard let player = player, player.duration > 0 else { return }
        let totalLength = text.count
        wordTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self, let player = self.player else { t.invalidate(); return }
            if !player.isPlaying {
                if player.currentTime >= player.duration - 0.01 {
                    t.invalidate()
                }
                return
            }
            let progress = Double(player.currentTime / player.duration)
            let endOffset = min(totalLength, Int(progress * Double(totalLength)))
            guard endOffset > 0 else { return }
            let end = text.index(text.startIndex, offsetBy: endOffset)
            let start = text.index(end, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let window: Substring
            if start > text.startIndex, let space = text[start...].firstIndex(of: " ") {
                window = text[text.index(after: space)..<end]
            } else {
                window = text[start..<end]
            }
            let display = String(window).trimmingCharacters(in: .whitespaces)
            if !display.isEmpty { self.onWord?(display) }
        }
    }

    private func finishAudio() {
        if audioRequestID == currentRequestID {
            currentRequestID = nil
        }
        audioRequestID = nil
        wordTimer?.invalidate()
        wordTimer = nil
        player?.stop()
        player?.delegate = nil
        player = nil
        if let f = audioFile {
            try? FileManager.default.removeItem(at: f)
            audioFile = nil
        }
        onSpeakEnd?()
    }

    static func elevenLabsVoices(apiKey: String) async -> [(String, String)] {
        guard !apiKey.isEmpty else { return [] }
        let url = URL(string: "https://api.elevenlabs.io/v1/voices")!
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                DebbyLog.write("ElevenLabs voices error \(status)")
                return []
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = obj["voices"] as? [[String: Any]] else { return [] }
            return voices.compactMap {
                guard let id = $0["voice_id"] as? String,
                      let name = $0["name"] as? String else { return nil }
                return (id, name)
            }.sorted { $0.1 < $1.1 }
        } catch {
            DebbyLog.write("ElevenLabs voices fetch failed: \(error.localizedDescription)")
            return []
        }
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

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id else { return }
            self.finishAudio()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == id, !self.activeText.isEmpty else { return }
            self.finishAudio()
            self.speakNative(self.activeText)
        }
    }
}

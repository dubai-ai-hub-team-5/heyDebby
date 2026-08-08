import Foundation

/// ElevenLabs text-to-speech. One request, one MP3 back; `SpeechOutput` plays it and, on
/// any failure, falls back to the native voice so Debby never goes silent.
///
/// Zero-dependency HTTPS, like the model backends. Auth is the `xi-api-key` header.
enum Eleven {
    /// "Sarah" — warm, reassuring, female; a good fit for Debby. Overridable in settings.
    static let defaultVoiceID = "EXAVITQu4vr4xnSDxMaL"
    /// The low-latency model — a spoken reply wants speed over the last ounce of fidelity.
    static let defaultModel = "eleven_flash_v2_5"

    static func tts(apiKey: String, voiceID: String, model: String, text: String) async throws -> Data {
        let vid = voiceID.isEmpty ? defaultVoiceID : voiceID
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(vid)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": model.isEmpty ? defaultModel : model,
            "voice_settings": ["stability": 0.4, "similarity_boost": 0.8, "use_speaker_boost": true],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            // Errors come back as JSON on this same body; surface it so a bad key or an
            // unknown voice id is diagnosable rather than a bare status code.
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "eleven", code: status, userInfo: [NSLocalizedDescriptionKey:
                "ElevenLabs \(status): \(msg.prefix(300))"])
        }
        return data
    }
}

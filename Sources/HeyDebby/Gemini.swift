import Foundation

enum Gemini {
    /// Matches All-In-One-AI's `DB_AGENT_MODEL` default.
    static let defaultModel = "gemini-3.1-flash-lite"

    static func send(apiKey: String, model: String,
                     history: [(role: String, text: String)],
                     userText: String, imageB64: String) async throws -> String {
        var contents: [[String: Any]] = []

        for h in history.suffix(6) {
            // Gemini uses "model" instead of "assistant"
            let role = h.role == "assistant" ? "model" : "user"
            contents.append(["role": role, "parts": [["text": h.text]]])
        }

        // An empty inlineData is a hard 400 ("Unable to process input image"), which reads like
        // a broken key rather than a missing screenshot. Send text only when there's no shot.
        var parts: [[String: Any]] = []
        if !imageB64.isEmpty {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": imageB64]])
        }
        parts.append(["text": userText])
        contents.append(["role": "user", "parts": parts])

        let m = model.isEmpty ? defaultModel : model
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Claude.systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                // flash models think by default and thinking spends this same budget, so 1024
                // got eaten before the reply started — the DRAWINGS JSON has to survive whole
                // or it silently parses to nothing. Thinking off, budget big enough for shapes.
                "maxOutputTokens": 4096,
                "temperature": 0.7,
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ]

        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent?key=\(apiKey)"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await NetworkSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let errMsg = ((try? JSONSerialization.jsonObject(with: data))
                .flatMap { ($0 as? [String: Any])?["error"] as? [String: Any] }?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? "unknown"
            throw geminiErr("Gemini API error \(status): \(errMsg)")
        }

        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let candidate = (obj?["candidates"] as? [[String: Any]])?.first
        guard let content = candidate?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              case let texts = parts.compactMap({ $0["text"] as? String }),
              !texts.isEmpty else {
            // finishReason is the whole diagnosis when the reply is empty: MAX_TOKENS means
            // the budget ran out, SAFETY means it was blocked. Without it this is unfixable.
            let why = candidate?["finishReason"] as? String ?? "no candidates"
            throw geminiErr("Gemini returned no text (finishReason: \(why))")
        }
        // Multi-part replies: join, don't take .first — dropping later parts would cut the
        // DRAWINGS line clean off.
        return texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func geminiErr(_ msg: String) -> NSError {
    NSError(domain: "gemini", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}

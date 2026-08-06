import Foundation

enum OpenAI {
    /// The fast, cheap member of the GPT-5.6 family. A lesson is a dozen turns, so this
    /// is the one that matters; gpt-5.6-terra and gpt-5.6-sol are settings away.
    static let defaultModel = "gpt-5.6-luna"

    /// One SSE line → the text it carries, or nil. Everything that isn't an output-text
    /// delta is noise here: lifecycle events, keep-alive blank lines, the [DONE] sentinel.
    /// The space after "data:" is conventional, not guaranteed (SSE only strips one
    /// leading space if present) — Codex.swift's parser already trims for the same
    /// endpoint family, so this does too rather than silently dropping deltas.
    static func delta(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
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
            return ["type": "message", "role": h.role, "content": [["type": type, "text": h.text]]]
        }
        var content: [[String: Any]] = [["type": "input_text", "text": userText]]
        // An empty input_image is a hard 400 that reads like a broken key rather than a
        // missing screenshot (same failure mode as Gemini's inlineData) — omit it entirely.
        if !imageB64.isEmpty {
            content.insert(["type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(imageB64)"], at: 0)
        }
        input.append(["type": "message", "role": "user", "content": content])

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
            for try await line in bytes.lines {
                detail += line
                if detail.count > 2000 { break }
            }
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

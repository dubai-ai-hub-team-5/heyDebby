import Foundation

// OpenHands-style Codex subscription backend: reuse the Codex CLI's ChatGPT OAuth
// token (~/.codex/auth.json) and call the Codex responses endpoint directly.
// The token never leaves this machine except to OpenAI's own API.
enum Codex {
    struct Auth {
        let accessToken: String
        let accountId: String
    }

    static var isLoggedIn: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json")
    }

    /// Same model the codex CLI uses (~/.codex/config.toml), so subscription model
    /// availability always matches. ponytail: first `model = "…"` line wins, no TOML parser.
    static var defaultModel: String {
        if let text = try? String(contentsOfFile: NSHomeDirectory() + "/.codex/config.toml", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("model") else { continue }
                let rest = t.dropFirst("model".count).trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix("=") else { continue }
                if let q1 = rest.firstIndex(of: "\""), let q2 = rest.lastIndex(of: "\""), q1 < q2 {
                    return String(rest[rest.index(after: q1)..<q2])
                }
            }
        }
        return "gpt-5.6-sol"
    }

    static func loadAuth() throws -> Auth {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw codexErr("Not signed in to Codex. Run `codex login` in a terminal (uses your ChatGPT subscription), then try again.")
        }
        var accountId = tokens["account_id"] as? String ?? ""
        if accountId.isEmpty, let idToken = tokens["id_token"] as? String {
            accountId = jwtAccountId(idToken) ?? ""
        }
        guard !accountId.isEmpty else {
            throw codexErr("Codex auth has no account id — run `codex login` again.")
        }
        return Auth(accessToken: access, accountId: accountId)
    }

    static func jwtAccountId(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = obj["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    static func send(model: String, history: [(role: String, text: String)],
                     userText: String, imageB64: String?) async throws -> String {
        let auth = try loadAuth()

        var input: [[String: Any]] = history.map {
            ["type": "message", "role": $0.role,
             "content": [["type": $0.role == "assistant" ? "output_text" : "input_text", "text": $0.text]]]
        }
        var content: [[String: Any]] = []
        // An empty (but non-nil) image_url is the same broken-key-looking 400 as Gemini's
        // inlineData and OpenAI's input_image — a Swift String passed to this String? param
        // promotes to Optional(""), which sails past `if let` unless isEmpty is checked too.
        if let img = imageB64, !img.isEmpty {
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(img)"])
        }
        content.append(["type": "input_text", "text": userText])
        input.append(["type": "message", "role": "user", "content": content])

        let body: [String: Any] = [
            "model": model,
            "instructions": Claude.systemPrompt,
            "input": input,
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "reasoning": ["effort": "low"],
            "store": false,
            "stream": true,
            "include": [],
        ]

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            var errBody = ""
            for try await line in bytes.lines {
                errBody += line
                if errBody.count > 2000 { break }
            }
            if status == 401 {
                throw codexErr("Codex session expired — run any codex command (e.g. `codex login`) to refresh, then retry.")
            }
            throw codexErr("Codex API error \(status): \(errBody)")
        }

        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "response.output_text.delta", let d = obj["delta"] as? String {
                text += d
            } else if type == "response.failed" {
                let msg = ((obj["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                throw codexErr("Codex request failed: \(msg ?? "unknown")")
            }
        }
        guard !text.isEmpty else { throw codexErr("Codex returned no text") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func codexErr(_ msg: String) -> NSError {
    NSError(domain: "codex", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}

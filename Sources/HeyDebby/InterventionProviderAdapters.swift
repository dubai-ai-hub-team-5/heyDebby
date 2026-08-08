import Foundation

private func interventionJSONData(from text: String) throws -> Data {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
        throw InterventionJSONError.malformedJSON
    }
    return Data(text[start...end].utf8)
}

struct OpenAIInterventionAdapter: DirectHTTPJSONInterventionAdapter, Sendable {
    let apiKey: String
    let model: String

    func makeRequest(for input: DirectHTTPInterventionInput) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "instructions": input.systemPrompt,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_image", "image_url": "data:\(input.imageMIMEType);base64,\(input.imageData.base64EncodedString())"],
                    ["type": "input_text", "text": input.userPrompt],
                ],
            ]],
            "stream": false,
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func extractDecisionJSON(from responseBody: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let output = object["output"] as? [[String: Any]] else {
            throw InterventionJSONError.malformedJSON
        }
        let text = output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
            .joined()
        return try interventionJSONData(from: text)
    }
}

struct AnthropicInterventionAdapter: DirectHTTPJSONInterventionAdapter, Sendable {
    let apiKey: String
    let model: String

    func makeRequest(for input: DirectHTTPInterventionInput) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": input.systemPrompt,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": input.imageMIMEType,
                            "data": input.imageData.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": input.userPrompt],
                ],
            ]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func extractDecisionJSON(from responseBody: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw InterventionJSONError.malformedJSON
        }
        let text = content.compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
        }.joined()
        return try interventionJSONData(from: text)
    }
}

struct GeminiInterventionAdapter: DirectHTTPJSONInterventionAdapter, Sendable {
    let apiKey: String
    let model: String

    func makeRequest(for input: DirectHTTPInterventionInput) throws -> URLRequest {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": input.systemPrompt]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": input.imageMIMEType, "data": input.imageData.base64EncodedString()]],
                    ["text": input.userPrompt],
                ],
            ]],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 512,
                "responseMimeType": "application/json",
            ],
        ]
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func extractDecisionJSON(from responseBody: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let candidate = (object["candidates"] as? [[String: Any]])?.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw InterventionJSONError.malformedJSON
        }
        return try interventionJSONData(from: parts.compactMap { $0["text"] as? String }.joined())
    }
}

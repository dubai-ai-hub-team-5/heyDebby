import Foundation

struct HandoffResult: Equatable, Sendable {
    let message: String
    let artifactURLs: [URL]
}

protocol DeterministicHandoffExecuting: Sendable {
    func execute(scenarioID: String, actionID: String, idempotencyKey: String) async throws
        -> HandoffResult
}

enum HandoffExecutorError: Error, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case failed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "The deterministic handoff endpoint is invalid"
        case .invalidResponse: return "The deterministic handoff returned an invalid response"
        case .failed(let status): return "The deterministic handoff failed (HTTP \(status))"
        }
    }
}

struct DeterministicGoogleHandoffExecutor: DeterministicHandoffExecuting, Sendable {
    let endpoint: URL
    let bearerToken: String
    let session: URLSession

    init(endpoint: URL, bearerToken: String, session: URLSession = NetworkSession.shared) throws {
        guard SourceReference.isValidHTTPSURL(endpoint), !bearerToken.isEmpty else {
            throw HandoffExecutorError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.session = session
    }

    func execute(scenarioID: String, actionID: String, idempotencyKey: String) async throws
        -> HandoffResult {
        let body: [String: String] = [
            "scenario_id": scenarioID,
            "action_id": actionID,
            "idempotency_key": idempotencyKey,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HandoffExecutorError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw HandoffExecutorError.failed(response.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["message", "artifact_urls"]),
              let message = object["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let strings = object["artifact_urls"] as? [String] else {
            throw HandoffExecutorError.invalidResponse
        }
        let urls = strings.compactMap(URL.init(string:)).filter(SourceReference.isValidHTTPSURL)
        guard urls.count == strings.count else { throw HandoffExecutorError.invalidResponse }
        return HandoffResult(message: message, artifactURLs: urls)
    }
}

import Foundation

/// Process-wide URLSessions with identical privacy defaults and purpose-specific timeouts.
/// Provider clients should reuse these instances so DNS, TLS, and HTTP/2 connections can be
/// warmed once instead of creating a new connection pool for every request.
enum NetworkSession {
    enum Purpose: String, Equatable, Sendable {
        case api
        case streaming
        case realtime
    }

    struct Timeouts: Equatable, Sendable {
        let request: TimeInterval
        let resource: TimeInterval
    }

    struct PrewarmTarget: Equatable, Sendable {
        let origin: URL
        let purpose: Purpose

        /// Only an HTTPS origin is retained. Paths, queries, fragments, and user info are dropped
        /// so a prewarm can never accidentally transmit a key embedded in a provider URL.
        init?(url: URL, purpose: Purpose) {
            guard let origin = NetworkSession.httpsOrigin(for: url) else { return nil }
            self.origin = origin
            self.purpose = purpose
        }
    }

    struct PrewarmResult: Equatable, Sendable {
        let origin: URL
        let purpose: Purpose
        /// Any HTTP response counts as warm; 401/404/405 still prove DNS and TLS succeeded.
        let reachedHost: Bool
        let statusCode: Int?
    }

    private struct IndexedPrewarmResult: Sendable {
        let index: Int
        let result: PrewarmResult
    }

    static let shared = makeSession(for: .api)
    static let streaming = makeSession(for: .streaming)
    static let realtime = makeSession(for: .realtime)

    static let defaultPrewarmTargets: [PrewarmTarget] = [
        makeTarget("https://api.anthropic.com", purpose: .api),
        makeTarget("https://api.openai.com", purpose: .streaming),
        makeTarget("https://generativelanguage.googleapis.com", purpose: .api),
        makeTarget("https://api.assemblyai.com", purpose: .api),
        makeTarget("https://streaming.assemblyai.com", purpose: .realtime),
    ]

    static func timeouts(for purpose: Purpose) -> Timeouts {
        switch purpose {
        case .api:
            return Timeouts(request: 45, resource: 240)
        case .streaming:
            return Timeouts(request: 90, resource: 900)
        case .realtime:
            return Timeouts(request: 30, resource: 86_400)
        }
    }

    /// Exposed as a construction seam so configuration invariants can be tested without making
    /// a network request. Every purpose is ephemeral, cookie-free, and cache-free.
    static func configuration(for purpose: Purpose) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let purposeTimeouts = timeouts(for: purpose)
        configuration.timeoutIntervalForRequest = purposeTimeouts.request
        configuration.timeoutIntervalForResource = purposeTimeouts.resource
        configuration.waitsForConnectivity = true

        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil

        configuration.httpMaximumConnectionsPerHost = 6
        return configuration
    }

    static func makeSession(for purpose: Purpose) -> URLSession {
        let session = URLSession(configuration: configuration(for: purpose))
        session.sessionDescription = "HeyDebby.\(purpose.rawValue)"
        return session
    }

    static func session(for purpose: Purpose) -> URLSession {
        switch purpose {
        case .api: return shared
        case .streaming: return streaming
        case .realtime: return realtime
        }
    }

    /// Performs credential-free HEAD requests concurrently. Results preserve target order and
    /// failures are reported as values so prewarming can remain a best-effort startup operation.
    @discardableResult
    static func prewarm(targets: [PrewarmTarget] = defaultPrewarmTargets,
                        timeout: TimeInterval = 8) async -> [PrewarmResult] {
        let boundedTimeout = min(max(timeout, 1), 30)
        return await withTaskGroup(of: IndexedPrewarmResult.self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    var request = URLRequest(
                        url: target.origin,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: boundedTimeout
                    )
                    request.httpMethod = "HEAD"
                    request.httpShouldHandleCookies = false

                    do {
                        let (_, response) = try await session(for: target.purpose).data(for: request)
                        let httpResponse = response as? HTTPURLResponse
                        return IndexedPrewarmResult(
                            index: index,
                            result: PrewarmResult(
                                origin: target.origin,
                                purpose: target.purpose,
                                reachedHost: httpResponse != nil,
                                statusCode: httpResponse?.statusCode
                            )
                        )
                    } catch {
                        return IndexedPrewarmResult(
                            index: index,
                            result: PrewarmResult(
                                origin: target.origin,
                                purpose: target.purpose,
                                reachedHost: false,
                                statusCode: nil
                            )
                        )
                    }
                }
            }

            var indexedResults: [IndexedPrewarmResult] = []
            indexedResults.reserveCapacity(targets.count)
            for await result in group {
                indexedResults.append(result)
            }
            return indexedResults.sorted { $0.index < $1.index }.map(\.result)
        }
    }

    private static func makeTarget(_ urlString: String, purpose: Purpose) -> PrewarmTarget {
        guard let url = URL(string: urlString),
              let target = PrewarmTarget(url: url, purpose: purpose) else {
            preconditionFailure("Invalid built-in network prewarm URL")
        }
        return target
    }

    private static func httpsOrigin(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }
}

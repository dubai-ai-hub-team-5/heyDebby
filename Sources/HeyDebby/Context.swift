import Foundation

/// Live web data, fetched the instant the model asks for it, via context.dev.
///
/// The chat brains answer in one shot — no tool-calling loop — so "pull live data" is
/// expressed as a `FETCH:` marker in the reply (see BeatSplitter): the model emits the URL
/// or query, `AppState` calls this, folds the result back into the prompt, and asks again.
/// Zero-dependency HTTPS, like every other backend here.
///
/// Auth is `Authorization: Bearer <key>`; base is `https://api.context.dev/v1`.
enum ContextDev {
    /// What a `FETCH:` payload resolves to. A URL (or bare domain) is scraped to Markdown;
    /// anything else is a web search.
    enum Request: Equatable {
        case scrape(String)   // an absolute URL to scrape into Markdown
        case search(String)   // a web-search query
    }

    /// Pure and testable: decide URL-vs-query without touching the network.
    ///
    /// `http(s)://…` and `www.…` are URLs. A bare token that looks like a domain
    /// (`apple.com`, no spaces, an alphabetic TLD) is treated as a URL too, so the model
    /// can say `FETCH: apple.com`. An explicit `search: …` forces a query. Everything else
    /// — anything with spaces, a decimal like `3.14` — is a query.
    static func parseRequest(_ raw: String) -> Request {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = t.lowercased()
        if low.hasPrefix("search:") {
            return .search(String(t.dropFirst("search:".count)).trimmingCharacters(in: .whitespaces))
        }
        if low.hasPrefix("http://") || low.hasPrefix("https://") { return .scrape(t) }
        if low.hasPrefix("www.") { return .scrape("https://" + t) }
        if looksLikeDomain(t) { return .scrape("https://" + t) }
        return .search(t)
    }

    /// No whitespace, and a host (the part before any path) whose last dotted segment is an
    /// alphabetic TLD of 2+ chars — enough to catch `stripe.com` and `gov.uk/renew` while
    /// rejecting `3.14` and prose.
    private static func looksLikeDomain(_ s: String) -> Bool {
        guard !s.contains(where: { $0.isWhitespace }) else { return false }
        let host = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        guard host.contains("."), let first = host.first, first.isLetter || first.isNumber
        else { return false }
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last else { return false }
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    /// Fetch and return a compact, LLM-ready block. Never throws for a "no results" case —
    /// it returns a line saying so, because the model still has to answer the user.
    static func fetch(_ raw: String, apiKey: String, maxChars: Int = 5000) async throws -> String {
        switch parseRequest(raw) {
        case .scrape(let url): return try await scrape(url, apiKey: apiKey, maxChars: maxChars)
        case .search(let query): return try await search(query, apiKey: apiKey, maxChars: maxChars)
        }
    }

    // MARK: - Endpoints

    private static func scrape(_ url: String, apiKey: String, maxChars: Int) async throws -> String {
        var comps = URLComponents(string: "https://api.context.dev/v1/web/scrape/markdown")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "useMainContentOnly", value: "true"),
            URLQueryItem(name: "includeImages", value: "false"),
        ]
        let obj = try await getJSON(comps.url!, apiKey: apiKey)
        let markdown = (obj["markdown"] as? String) ?? ""
        let title = ((obj["metadata"] as? [String: Any])?["title"] as? String) ?? url
        let finalURL = ((obj["metadata"] as? [String: Any])?["finalUrl"] as? String) ?? url
        guard !markdown.isEmpty else { return "Source \(title) (\(finalURL)) returned no readable content." }
        return "Live page — \(title)\nURL: \(finalURL)\n\n\(clip(markdown, maxChars))"
    }

    private static func search(_ query: String, apiKey: String, maxChars: Int) async throws -> String {
        let body: [String: Any] = ["query": query, "numResults": 10]
        let obj = try await postJSON(URL(string: "https://api.context.dev/v1/web/search")!,
                                     apiKey: apiKey, body: body)
        let results = (obj["results"] as? [[String: Any]]) ?? []
        guard !results.isEmpty else { return "Web search for \"\(query)\" returned no results." }
        var out = "Live web search for \"\(query)\":\n"
        for (i, r) in results.prefix(8).enumerated() {
            let title = (r["title"] as? String) ?? "(untitled)"
            let desc = (r["description"] as? String) ?? ""
            let u = (r["url"] as? String) ?? ""
            out += "\n\(i + 1). \(title)\n   \(desc)\n   \(u)\n"
        }
        return clip(out, maxChars)
    }

    // MARK: - Transport

    private static func getJSON(_ url: URL, apiKey: String) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 45
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private static func postJSON(_ url: URL, apiKey: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60   // a cold crawl can take a while
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let msg = (obj?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "unknown"
            throw contextErr("context.dev \(status): \(msg)")
        }
        guard let obj else { throw contextErr("context.dev returned a non-JSON response") }
        return obj
    }

    /// A page can be huge; the prompt has a budget. Keep the head — the price, the headline,
    /// the answer are almost always near the top of clean Markdown.
    private static func clip(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "\n…(truncated)"
    }
}

func contextErr(_ msg: String) -> NSError {
    NSError(domain: "context", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}

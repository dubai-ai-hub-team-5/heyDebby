import Foundation

/// Pre-opens a TLS session to the hosts the first question will hit.
///
/// The first request of a run carries a base64 screenshot, so it is the one request least
/// able to afford a cold handshake on top of its own upload. A HEAD to the bare host costs
/// nothing and leaves a pooled connection — and a cached TLS session ticket — behind for
/// the real call. `URLSession.shared` is the point: every backend in this app goes through
/// it, so they all draw from the pool this fills. A private session would warm a pool
/// nobody reads.
///
/// Best-effort by construction — the response is discarded and failures are ignored. A
/// warmup that didn't land just means the first call pays what it would have paid anyway.
enum Warmup {
    /// Hosts worth warming for a given brain + voice choice. Pure, so the selfcheck can
    /// assert the mapping without opening a socket. `claudecli` is absent on purpose: it
    /// shells out to a CLI that opens its own connections, and warming Anthropic would do
    /// nothing for it.
    static func hosts(brain: String, voiceSource: String) -> [String] {
        var out: [String] = []
        switch brain {
        case "claude": out.append("https://api.anthropic.com")
        case "openai": out.append("https://api.openai.com")
        case "gemini": out.append("https://generativelanguage.googleapis.com")
        case "codex":  out.append("https://chatgpt.com")
        default: break
        }
        if voiceSource == "elevenlabs" { out.append("https://api.elevenlabs.io") }
        return out
    }

    private static var warmed = Set<String>()

    /// Fires once per host per launch. Repeat calls are free, so this can sit on a settings
    /// change as well as on launch — switching brain mid-session warms the new one.
    @MainActor
    static func begin(brain: String, voiceSource: String) {
        for host in hosts(brain: brain, voiceSource: voiceSource) where !warmed.contains(host) {
            warmed.insert(host)
            guard let url = URL(string: host) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        }
    }
}

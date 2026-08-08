import Foundation

enum MediaApp: String, Decodable, Equatable {
    case music
    case spotify
}

enum MediaCommand: String, Decodable, Equatable {
    case playPause = "play_pause"
    case next
    case previous
}

enum AppAction: Decodable, Equatable {
    case setVolume(Int)
    case changeVolume(Int)
    case media(app: MediaApp, command: MediaCommand)

    private enum CodingKeys: String, CodingKey { case type, value, app, command }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "set_volume":
            let value = try c.decode(Int.self, forKey: .value)
            guard (0...100).contains(value) else { throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "volume out of range") }
            self = .setVolume(value)
        case "change_volume":
            let value = try c.decode(Int.self, forKey: .value)
            guard (-20...20).contains(value) else { throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "volume delta out of range") }
            self = .changeVolume(value)
        case "media":
            self = .media(app: try c.decode(MediaApp.self, forKey: .app),
                          command: try c.decode(MediaCommand.self, forKey: .command))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown action")
        }
    }

    /// JSONDecoder deliberately ignores unknown keys. At this trust boundary, that would
    /// let a model hide executable-looking data beside an otherwise valid action.
    static func decodeStrict(_ json: String) -> AppAction? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dictionary = object as? [String: Any], let type = dictionary["type"] as? String
        else { return nil }
        let expected: Set<String>
        switch type {
        case "set_volume", "change_volume": expected = ["type", "value"]
        case "media": expected = ["type", "app", "command"]
        default: return nil
        }
        guard Set(dictionary.keys) == expected else { return nil }
        return try? JSONDecoder().decode(AppAction.self, from: Data(json.utf8))
    }
}

/// One unit of a lesson, in the order the model emitted it.
enum Beat: Equatable {
    case say(String)
    case draw(ShapeSpec)
    case point(Annotation)
    case action(AppAction)
}

/// Splits a model reply — streamed in fragments or handed over whole — into ordered beats.
///
/// One marker per line, unlike the `DRAWINGS: [ … ]` block this replaces. A line is the
/// smallest thing a stream lets you be sure is complete; a JSON array is only complete at
/// its closing bracket, which arrives after every shape it contains. Prose is released at
/// the newline, once `normalize()` has had a chance to strip decoration — the system prompt
/// puts each `DRAW:`/`POINT:`/`MORE:` on its own line right after the sentence describing it,
/// so in this format a line already is a sentence; there is no gain in releasing mid-line.
struct BeatSplitter {
    private(set) var more = false
    /// Live-web-data requests the model asked for (`FETCH:` lines). Not a beat: nothing is
    /// spoken or drawn — `AppState` fetches each, then re-asks the model with the results.
    private(set) var fetches: [String] = []

    private var line = ""    // characters since the last newline
    private var prose = ""   // prose accumulating toward a sentence end

    mutating func feed(_ chunk: String) -> [Beat] {
        var out: [Beat] = []
        for ch in chunk {
            // `isNewline`, not `== "\n"`: a PTY-wrapped subprocess (or a model backend)
            // writes "\r\n". Swift fuses that into one grapheme cluster distinct from
            // plain "\n" whenever both bytes land in the same chunk, so `== "\n"` never
            // matches and the line never terminates. `isNewline` also catches a lone "\r"
            // when the chunk boundary falls between the \r and the \n.
            if ch.isNewline { out += flushLine() } else { line.append(ch) }
        }
        return out
    }

    /// End of stream: the last line has no newline and the last sentence may have no
    /// terminator. Both still have to be said.
    mutating func finish() -> [Beat] {
        var out = flushLine()
        out += flushProse()
        return out
    }

    private mutating func flushLine() -> [Beat] {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        line = ""
        let l = Self.normalize(raw)
        if l.isEmpty { return prose.isEmpty ? [] : releaseSentences() }

        if let json = Self.payload(l, "DRAW:") {
            var out = flushProse()   // the sentence before a marker is finished by it
            if let s = try? JSONDecoder().decode(ShapeSpec.self, from: Data(json.utf8)) {
                out.append(.draw(s))
            } else {
                // Silent otherwise: PARSED drawings=N only counts survivors, so a line that
                // never decoded at all would be indistinguishable from "drew nothing".
                DebbyLog.write("BEAT DRAW: did not decode: \(json.prefix(120))")
            }
            return out
        }
        if let json = Self.payload(l, "POINT:") {
            var out = flushProse()
            if let a = try? JSONDecoder().decode(Annotation.self, from: Data(json.utf8)) {
                out.append(.point(a))
            } else {
                DebbyLog.write("BEAT POINT: did not decode: \(json.prefix(120))")
            }
            return out
        }
        if let json = Self.payload(l, "ACTION:") {
            var out = flushProse()
            if let action = AppAction.decodeStrict(json) {
                out.append(.action(action))
            } else {
                DebbyLog.write("BEAT ACTION: rejected invalid payload")
            }
            return out
        }
        if let target = Self.payload(l, "FETCH:") {
            let out = flushProse()   // the sentence before a marker is finished by it
            if target.isEmpty { DebbyLog.write("BEAT FETCH: empty payload") }
            else { fetches.append(target) }
            return out
        }
        if let rest = Self.payload(l, "MORE:") {
            more = rest.lowercased().contains("yes")
            return []
        }
        // Prose. A newline does NOT end a sentence: the line is appended with a trailing
        // space, and unterminated lines keep accumulating in `prose` until real punctuation
        // ends a sentence (releaseSentences() below) or finish() flushes what's left. `**`
        // is stripped here rather than in normalize() because only prose is safe to rewrite.
        prose += l.replacingOccurrences(of: "**", with: "") + " "
        return releaseSentences()
    }

    /// Strips what models decorate lines with. A fence line carries no content at all.
    ///
    /// Bold is only removed around the marker keyword — everything past the colon is a
    /// JSON payload, and stripping `**` there silently rewrites any label that contains
    /// asterisks.
    private static func normalize(_ s: String) -> String {
        if s.hasPrefix("```") { return "" }
        var t = s
        for junk in ["- ", "* "] where t.hasPrefix(junk) {
            t = String(t.dropFirst(junk.count))
        }
        if let colon = t.firstIndex(of: ":") {
            let head = t[...colon].replacingOccurrences(of: "**", with: "")
            var tail = String(t[t.index(after: colon)...])
            if tail.hasPrefix("**") { tail = String(tail.dropFirst(2)) }
            t = head + tail
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func payload(_ line: String, _ marker: String) -> String? {
        guard line.uppercased().hasPrefix(marker) else { return nil }
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Emits every complete sentence in `prose`. A sentence ends at `.`, `!` or `?`
    /// followed by whitespace that has actually arrived — so `3.14` stays whole, and a
    /// final sentence with nothing after it waits for `finish()`.
    private mutating func releaseSentences() -> [Beat] {
        var out: [Beat] = []
        while let end = Self.sentenceEnd(in: prose) {
            let s = String(prose[..<end]).trimmingCharacters(in: .whitespaces)
            prose = String(prose[end...])
            if !s.isEmpty { out.append(.say(s)) }
        }
        return out
    }

    private static func sentenceEnd(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if ".!?".contains(s[i]) {
                let next = s.index(after: i)
                if next < s.endIndex, s[next].isWhitespace { return next }
            }
            i = s.index(after: i)
        }
        return nil
    }

    private mutating func flushProse() -> [Beat] {
        var out = releaseSentences()
        let rest = prose.trimmingCharacters(in: .whitespaces)
        prose = ""
        if !rest.isEmpty { out.append(.say(rest)) }
        return out
    }
}

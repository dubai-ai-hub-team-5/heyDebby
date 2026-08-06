import Foundation

/// One unit of a lesson, in the order the model emitted it.
enum Beat: Equatable {
    case say(String)
    case draw(ShapeSpec)
    case point(Annotation)
    case run(String)     // one AppleScript statement, run as osascript arguments
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

    private var line = ""    // characters since the last newline
    private var prose = ""   // prose accumulating toward a sentence end

    mutating func feed(_ chunk: String) -> [Beat] {
        var out: [Beat] = []
        for ch in chunk {
            if ch == "\n" { out += flushLine() } else { line.append(ch) }
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
        let raw = line.trimmingCharacters(in: .whitespaces)
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
        if let script = Self.payload(l, "RUN:") {
            var out = flushProse()
            if script.isEmpty {
                DebbyLog.write("BEAT RUN: empty payload")
            } else if Self.shellsOut(script) {
                // AppleScript's escape hatch to the shell. The payload is model-written and
                // the model reads the user's screen, so this is a prompt-injection path, not
                // a hypothetical. Refuse it here, before Control ever sees it.
                DebbyLog.write("BEAT RUN: refused, shells out: \(script.prefix(120))")
            } else {
                out.append(.run(script))
            }
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
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Every form the parser refuses, in the casing the system prompt should quote them in.
    /// Shared (not just an implementation detail of `shellsOut`) so a selfcheck can assert
    /// the prompt documents every one of these — the two lists drifting apart silently is
    /// exactly what would let a model narrate an action that got dropped on the floor.
    static let refusedForms = [
        "do shell script",   // the shell, directly
        "do script",         // Terminal / Script Editor run a command
        "run script",        // evaluates AppleScript text at runtime
        "load script",       // loads a script object, then `run` executes it
        // Terminal emulators by any of their spellings: bare name, "Terminal.app", or
        // `tell application id "com.apple.Terminal"`.
        "Terminal", "iTerm", "Script Editor",
    ]

    /// AppleScript's routes to running arbitrary code. This is a denylist, and it is
    /// honest about being one.
    ///
    /// It holds for AppleScript's eval primitives: a keyword must appear literally in the
    /// source to execute, so `do shell script` cannot be assembled from concatenated
    /// strings without first calling `run script` or `load script` — and those are on the
    /// list. Whitespace is normalised because AppleScript is whitespace-insensitive
    /// between tokens.
    ///
    /// It does NOT hold for GUI scripting. `tell application "System Events" to keystroke`
    /// is deliberately allowed — it is how non-scriptable apps are reached — and keystrokes
    /// can open Spotlight and type into a terminal without naming one. This rail blocks
    /// direct shell-out and eval. It is not a boundary against a model that has been
    /// induced by on-screen content to type a command.
    private static func shellsOut(_ s: String) -> Bool {
        let flat = s.uppercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return refusedForms.contains { flat.contains($0.uppercased()) }
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

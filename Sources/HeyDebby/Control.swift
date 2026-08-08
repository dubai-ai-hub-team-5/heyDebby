import Foundation

/// Executes only validated `AppAction` values. Model-authored text never reaches argv.
enum Control {
    static let executablePath = "/usr/bin/osascript"

    static func arguments(for action: AppAction) -> [String] {
        let statement: String
        switch action {
        case .setVolume(let value):
            statement = "set volume output volume \(value)"
        case .changeVolume(let delta):
            statement = """
            set currentVolume to output volume of (get volume settings)
            set targetVolume to currentVolume + \(delta)
            if targetVolume < 0 then set targetVolume to 0
            if targetVolume > 100 then set targetVolume to 100
            set volume output volume targetVolume
            """
        case .media(let app, let command):
            let application = app == .music ? "Music" : "Spotify"
            let verb: String
            switch command {
            case .playPause: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            }
            statement = "tell application \"\(application)\" to \(verb)"
        }
        return ["-e", statement]
    }

    /// Runs one typed action and reports the exit code plus osascript output.
    /// `onDone` always lands on the main queue because the caller owns UI state.
    static func run(_ action: AppAction, onDone: @escaping (Int32, String) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments(for: action)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        let box = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) { box.append(text) }
        }
        DebbyLog.write("ACTION \(action)")
        proc.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let text = box.text
            DebbyLog.write("ACTION exit \(p.terminationStatus) \(text.prefix(200))")
            DispatchQueue.main.async { onDone(p.terminationStatus, text) }
        }
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async { onDone(-1, error.localizedDescription) }
        }
    }
}

import AppKit
import Foundation

/// Everything Debby shells out to, on disk. The notch only ever shows the newest line
/// of an agent run, so without this a failure mid-run leaves nothing to look at.
/// Local file, never uploaded — but it does contain your prompts and agent output.
enum DebbyLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/HeyDebby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debby.log")
    }()

    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Timestamped line — for events (a run starting, an exit code, an error).
    static func write(_ text: String) { emit("[\(stamp.string(from: Date()))] \(text)\n") }

    /// Verbatim — for streaming CLI output, which is already line-formatted.
    static func raw(_ text: String) { emit(text) }

    private static func emit(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        // ponytail: trim from the front at 2 MB. A real rotator when someone misses the old lines.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000,
           let old = try? String(contentsOf: url, encoding: .utf8) {
            try? String(old.suffix(500_000)).write(to: url, atomically: true, encoding: .utf8)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: url.path) {
            write("(nothing has run yet)")
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

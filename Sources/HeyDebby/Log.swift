import AppKit
import Foundation

/// A protected, bounded local log destination. Keeping this separate from the global
/// facade lets process boundaries be tested against a real temporary file.
final class LogSink: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(url: URL) { self.url = url }

    func write(_ text: String) { emit("[\(stamp.string(from: Date()))] \(text)\n") }
    func raw(_ text: String) { emit(text) }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func emit(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: data,
                                    attributes: [.posixPermissions: 0o600]) else { return }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let size = try fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 2_000_000,
               let old = try? String(contentsOf: url, encoding: .utf8),
               let replacement = String(old.suffix(500_000)).data(using: .utf8) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: replacement)
                try handle.close()
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Logging must never terminate the app or replace the original operation's error.
        }
    }
}

/// Everything Debby shells out to, on disk. Local only, but ordinary runs contain prompts
/// and output. Privacy-sensitive operations select private logging before reaching here.
enum DebbyLog {
    static let url: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/HeyDebby/debby.log")
    }()
    private static let sink = LogSink(url: url)

    static func write(_ text: String) { sink.write(text) }
    static func raw(_ text: String) { sink.raw(text) }
    static func delete() throws { try sink.delete() }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: url.path) { write("(nothing has run yet)") }
        NSWorkspace.shared.selectFile(url.path,
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

import Foundation

/// The user's own details, extracted from their documents once and reused.
///
/// Application Support rather than ~/Documents: that folder syncs to iCloud, and this
/// file holds a passport number. `0600` because it holds a passport number.
enum Profile {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("HeyDebby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }()

    /// Models wrap JSON in fences and chat around it. Take the outermost braces and
    /// validate — writing unvalidated text would turn a chatty reply into a broken profile.
    static func extractJSON(_ raw: String) -> String? {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"),
              open < close else { return nil }
        let candidate = String(raw[open...close])
        guard (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil
        else { return nil }
        return candidate
    }

    static func write(_ json: String) throws {
        try json.data(using: .utf8)?.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static var lastScanned: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}

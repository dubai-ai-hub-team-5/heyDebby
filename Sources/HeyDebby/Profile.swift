import Foundation

struct ProfileField: Codable, Equatable {
    let value: String
    let source: String
}

enum ProfileError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// The user's own details, extracted from their documents once and reused.
enum Profile {
    static let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("HeyDebby", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        return directory.appendingPathComponent("profile.json")
    }()

    static func validateAndEncode(_ raw: String, allowedRoots: [URL]) throws -> Data {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close
        else { throw ProfileError.invalid("The scan did not return a profile object") }
        let candidate = Data(raw[open...close].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: candidate),
              let fields = object as? [String: Any], !fields.isEmpty
        else { throw ProfileError.invalid("The scan returned invalid profile JSON") }

        let roots = allowedRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        }
        guard !roots.isEmpty else { throw ProfileError.invalid("No document folder was allowed") }

        var validated: [String: ProfileField] = [:]
        for (name, rawField) in fields {
            guard validFieldName(name) else {
                throw ProfileError.invalid("The scan returned an invalid field name")
            }
            guard let field = rawField as? [String: Any],
                  Set(field.keys) == ["value", "source"],
                  let rawValue = field["value"] as? String,
                  let rawSource = field["source"] as? String else {
                throw ProfileError.invalid("The scan returned an invalid field")
            }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceText = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 4_096, !containsControlCharacter(value),
                  !sourceText.isEmpty, sourceText.count <= 4_096,
                  !containsControlCharacter(sourceText) else {
                throw ProfileError.invalid("The scan returned an invalid field value")
            }

            let expanded = (sourceText as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ProfileError.invalid("A profile source was not an absolute path")
            }
            let source = URL(fileURLWithPath: expanded).standardizedFileURL
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  roots.contains(where: { contains(resolved, in: $0) }) else {
                throw ProfileError.invalid("A profile source was outside the scanned folder")
            }
            validated[name] = ProfileField(value: value, source: source.path)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(validated)
    }

    static func write(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static var lastScanned: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func isValidStoredData(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any], !fields.isEmpty else { return false }
        return fields.allSatisfy { name, rawField in
            guard validFieldName(name), let field = rawField as? [String: Any],
                  Set(field.keys) == ["value", "source"],
                  let value = field["value"] as? String, !value.isEmpty,
                  let source = field["source"] as? String, source.hasPrefix("/")
            else { return false }
            return true
        }
    }

    static var validStoredProfileURL: URL? {
        guard let data = try? Data(contentsOf: url), isValidStoredData(data) else { return nil }
        return url
    }

    static func deletePrivateData(profileURL: URL = url, logURL: URL = DebbyLog.url) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: profileURL.path) { try fm.removeItem(at: profileURL) }
        if fm.fileExists(atPath: logURL.path) { try fm.removeItem(at: logURL) }
    }

    private static func validFieldName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              (97...122).contains(first.value), !name.hasSuffix("_"), !name.contains("__")
        else { return false }
        return name.unicodeScalars.allSatisfy {
            (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 95
        }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func contains(_ file: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(rootPath)
    }
}

import Foundation

/// An opaque identifier for a source the application has trusted ahead of time.
///
/// Model output may name one of these identifiers, but it can never manufacture a
/// `SourceReference`: references have no `Decodable` conformance and are resolved from the
/// trusted evidence supplied to an evaluation.
struct SourceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = SourceID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid source identifier")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    private static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count),
              let first = bytes.first, let last = bytes.last,
              isLowercaseLetterOrDigit(first), isLowercaseLetterOrDigit(last) else { return false }

        var previousWasSeparator = false
        for byte in bytes {
            if isLowercaseLetterOrDigit(byte) {
                previousWasSeparator = false
            } else if byte == 45 || byte == 46 || byte == 95 { // -, ., _
                guard !previousWasSeparator else { return false }
                previousWasSeparator = true
            } else {
                return false
            }
        }
        return true
    }

    private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }
}

enum SourceReferenceValidationError: Error, Equatable {
    case invalidTitle
    case invalidHTTPSURL
    case invalidLocalFileURL
    case localFileIsNotRegular
}

/// A source selected by trusted application configuration, never by model output.
struct SourceReference: Hashable, Sendable {
    enum Location: Hashable, Sendable {
        case https(URL)
        case localFile(URL)
    }

    let id: SourceID
    let title: String
    let location: Location

    init(id: SourceID, title: String, httpsURL: URL) throws {
        guard let title = Self.validatedTitle(title) else {
            throw SourceReferenceValidationError.invalidTitle
        }
        guard Self.isValidHTTPSURL(httpsURL) else {
            throw SourceReferenceValidationError.invalidHTTPSURL
        }
        self.id = id
        self.title = title
        self.location = .https(httpsURL)
    }

    /// Resolves symlinks and verifies that the resulting URL is an existing regular file.
    /// Directories, sockets, devices, relative file URLs, and remote `file://` hosts fail closed.
    init(id: SourceID, title: String, localFileURL: URL) throws {
        guard let title = Self.validatedTitle(title) else {
            throw SourceReferenceValidationError.invalidTitle
        }
        guard localFileURL.isFileURL, localFileURL.baseURL == nil,
              localFileURL.path.hasPrefix("/") else {
            throw SourceReferenceValidationError.invalidLocalFileURL
        }
        if let host = URLComponents(url: localFileURL, resolvingAgainstBaseURL: false)?.host,
           !host.isEmpty, host.lowercased() != "localhost" {
            throw SourceReferenceValidationError.invalidLocalFileURL
        }

        let resolvedURL = localFileURL.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
            throw SourceReferenceValidationError.localFileIsNotRegular
        }
        guard values.isRegularFile == true else {
            throw SourceReferenceValidationError.localFileIsNotRegular
        }

        self.id = id
        self.title = title
        self.location = .localFile(resolvedURL)
    }

    var url: URL {
        switch location {
        case .https(let url), .localFile(let url): return url
        }
    }

    var isLocalFile: Bool {
        if case .localFile = location { return true }
        return false
    }

    static func isValidHTTPSURL(_ url: URL) -> Bool {
        guard url.baseURL == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        if let port = components.port, !(1...65_535).contains(port) { return false }
        return true
    }

    private static func validatedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 160,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }
}

/// The only executable-looking affordance an intervention can carry. The UI must resolve the
/// identifier against `Intervention.sources`; arbitrary URLs and arbitrary action names are not
/// representable.
enum SuggestedAction: Hashable, Sendable {
    case openSource(SourceID)

    var sourceID: SourceID {
        switch self {
        case .openSource(let sourceID): return sourceID
        }
    }
}

struct InterventionAnnotation: Equatable, Sendable {
    let x: Double
    let y: Double
    let label: String

    init(x: Double, y: Double, label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              !label.isEmpty, label.utf8.count <= 80,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw InterventionValidationError.invalidAnnotation }
        self.x = x
        self.y = y
        self.label = label
    }
}

enum InterventionValidationError: Error, Equatable {
    case invalidTitle
    case invalidMessage
    case invalidConfidence
    case invalidAnnotation
    case missingSources
    case duplicateSources
    case untrustedActionSource
}

struct Intervention: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let confidence: Double
    let annotation: InterventionAnnotation
    let sources: [SourceReference]
    let suggestedAction: SuggestedAction?

    /// Computed locally rather than accepted from a model, so changing a model-provided nonce
    /// cannot bypass duplicate suppression.
    fileprivate let deduplicationKey: String

    init(
        id: UUID = UUID(),
        title: String,
        message: String,
        confidence: Double,
        annotation: InterventionAnnotation,
        sources: [SourceReference],
        suggestedAction: SuggestedAction? = nil
    ) throws {
        guard let title = Self.validatedModelText(title, maximumUTF8Count: 100) else {
            throw InterventionValidationError.invalidTitle
        }
        guard let message = Self.validatedModelText(message, maximumUTF8Count: 500) else {
            throw InterventionValidationError.invalidMessage
        }
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw InterventionValidationError.invalidConfidence
        }
        guard !sources.isEmpty, sources.count <= 8 else {
            throw InterventionValidationError.missingSources
        }
        let sourceIDs = Set(sources.map(\.id))
        guard sourceIDs.count == sources.count else {
            throw InterventionValidationError.duplicateSources
        }
        if let suggestedAction, !sourceIDs.contains(suggestedAction.sourceID) {
            throw InterventionValidationError.untrustedActionSource
        }

        self.id = id
        self.title = title
        self.message = message
        self.confidence = confidence
        self.annotation = annotation
        self.sources = sources
        self.suggestedAction = suggestedAction
        self.deduplicationKey = Self.makeDeduplicationKey(
            title: title,
            sourceIDs: sourceIDs,
            action: suggestedAction
        )
    }

    /// Resolves an action only within this intervention's already-trusted source set.
    func source(for action: SuggestedAction) -> SourceReference? {
        sources.first { $0.id == action.sourceID }
    }

    private static func validatedModelText(_ value: String, maximumUTF8Count: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Count,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        // Intervention copy is display-only. Refuse URL-like text so a view that happens to
        // auto-link strings cannot turn model prose into a second, untrusted source affordance.
        let lowercased = trimmed.lowercased()
        guard !["https://", "http://", "file://", "www."].contains(where: lowercased.contains)
        else { return nil }
        return trimmed
    }

    private static func makeDeduplicationKey(
        title: String,
        sourceIDs: Set<SourceID>,
        action: SuggestedAction?
    ) -> String {
        let normalizedTitle = title
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let sources = sourceIDs.map(\.rawValue).sorted().joined(separator: ",")
        let actionKey = action.map { "open-source:\($0.sourceID.rawValue)" } ?? "no-action"
        return "\(sources)|\(actionKey)|\(normalizedTitle)"
    }
}

enum InterventionVerdict: Equatable, Sendable {
    case noIntervention(confidence: Double)
    case intervene(Intervention)

    var confidence: Double {
        switch self {
        case .noIntervention(let confidence): return confidence
        case .intervene(let intervention): return intervention.confidence
        }
    }

    var proposedIntervention: Intervention? {
        if case .intervene(let intervention) = self { return intervention }
        return nil
    }
}

enum InterventionJSONError: Error, Equatable {
    case responseTooLarge
    case malformedJSON
    case unexpectedKeys
    case invalidVerdict
    case invalidConfidence
    case invalidSources
    case untrustedSource
    case invalidAction
    case invalidIntervention
}

extension InterventionVerdict {
    /// Decodes the complete model response. JSONDecoder normally ignores unknown keys; the
    /// explicit shape checks here make every extra URL/action field a hard failure.
    static func decodeStrictJSON(
        _ data: Data,
        trustedSources: [SourceReference]
    ) throws -> InterventionVerdict {
        guard data.count <= 32_768 else { throw InterventionJSONError.responseTooLarge }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InterventionJSONError.malformedJSON
        }
        guard let dictionary = object as? [String: Any],
              let verdictName = dictionary["verdict"] as? String else {
            throw InterventionJSONError.malformedJSON
        }

        var sourcesByID: [SourceID: SourceReference] = [:]
        for source in trustedSources {
            guard sourcesByID[source.id] == nil else {
                throw InterventionJSONError.invalidSources
            }
            sourcesByID[source.id] = source
        }

        switch verdictName {
        case "no_intervention":
            guard Set(dictionary.keys) == ["verdict", "confidence"] else {
                throw InterventionJSONError.unexpectedKeys
            }
            let raw: RawNoIntervention
            do {
                raw = try JSONDecoder().decode(RawNoIntervention.self, from: data)
            } catch {
                throw InterventionJSONError.malformedJSON
            }
            guard raw.verdict == verdictName, raw.confidence.isFinite,
                  (0...1).contains(raw.confidence) else {
                throw InterventionJSONError.invalidConfidence
            }
            return .noIntervention(confidence: raw.confidence)

        case "intervene":
            let expectedKeys: Set<String> = [
                "verdict", "confidence", "title", "message", "annotation", "source_ids", "suggested_action",
            ]
            guard Set(dictionary.keys) == expectedKeys else {
                throw InterventionJSONError.unexpectedKeys
            }

            guard let annotationObject = dictionary["annotation"] as? [String: Any],
                  Set(annotationObject.keys) == ["x", "y", "label"] else {
                throw InterventionJSONError.invalidIntervention
            }
            if let actionObject = dictionary["suggested_action"], !(actionObject is NSNull) {
                guard let actionDictionary = actionObject as? [String: Any],
                      Set(actionDictionary.keys) == ["type", "source_id"] else {
                    throw InterventionJSONError.invalidAction
                }
            }

            let raw: RawIntervention
            do {
                raw = try JSONDecoder().decode(RawIntervention.self, from: data)
            } catch {
                throw InterventionJSONError.malformedJSON
            }
            guard raw.verdict == verdictName, raw.confidence.isFinite,
                  (0...1).contains(raw.confidence) else {
                throw InterventionJSONError.invalidConfidence
            }
            guard (1...8).contains(raw.sourceIDs.count),
                  Set(raw.sourceIDs).count == raw.sourceIDs.count else {
                throw InterventionJSONError.invalidSources
            }

            var resolvedSources: [SourceReference] = []
            for sourceID in raw.sourceIDs {
                guard let source = sourcesByID[sourceID] else {
                    throw InterventionJSONError.untrustedSource
                }
                resolvedSources.append(source)
            }

            let action: SuggestedAction?
            if let rawAction = raw.suggestedAction {
                guard rawAction.type == "open_source",
                      raw.sourceIDs.contains(rawAction.sourceID),
                      sourcesByID[rawAction.sourceID] != nil else {
                    throw InterventionJSONError.invalidAction
                }
                action = .openSource(rawAction.sourceID)
            } else {
                action = nil
            }

            do {
                let annotation = try InterventionAnnotation(
                    x: raw.annotation.x,
                    y: raw.annotation.y,
                    label: raw.annotation.label
                )
                let intervention = try Intervention(
                    title: raw.title,
                    message: raw.message,
                    confidence: raw.confidence,
                    annotation: annotation,
                    sources: resolvedSources,
                    suggestedAction: action
                )
                return .intervene(intervention)
            } catch {
                throw InterventionJSONError.invalidIntervention
            }

        default:
            throw InterventionJSONError.invalidVerdict
        }
    }

    static func decodeStrictJSON(
        _ json: String,
        trustedSources: [SourceReference]
    ) throws -> InterventionVerdict {
        try decodeStrictJSON(Data(json.utf8), trustedSources: trustedSources)
    }

    private struct RawNoIntervention: Decodable {
        let verdict: String
        let confidence: Double
    }

    private struct RawIntervention: Decodable {
        let verdict: String
        let confidence: Double
        let title: String
        let message: String
        let annotation: RawAnnotation
        let sourceIDs: [SourceID]
        let suggestedAction: RawSuggestedAction?

        private enum CodingKeys: String, CodingKey {
            case verdict, confidence, title, message, annotation
            case sourceIDs = "source_ids"
            case suggestedAction = "suggested_action"
        }
    }

    private struct RawAnnotation: Decodable {
        let x: Double
        let y: Double
        let label: String
    }

    private struct RawSuggestedAction: Decodable {
        let type: String
        let sourceID: SourceID

        private enum CodingKeys: String, CodingKey {
            case type
            case sourceID = "source_id"
        }
    }
}

/// Mutable delivery memory owned by an `InterventionPolicy`.
struct InterventionState: Equatable, Sendable {
    private(set) var lastPresentedAt: Date?
    private(set) var presentedCount: Int
    private(set) var deliveredDeduplicationKeys: Set<String>
    private var deliveryOrder: [String]

    init() {
        lastPresentedAt = nil
        presentedCount = 0
        deliveredDeduplicationKeys = []
        deliveryOrder = []
    }

    func hasDelivered(_ intervention: Intervention) -> Bool {
        deliveredDeduplicationKeys.contains(intervention.deduplicationKey)
    }

    mutating func reset() {
        self = InterventionState()
    }

    fileprivate mutating func record(
        _ intervention: Intervention,
        at date: Date,
        historyLimit: Int
    ) {
        lastPresentedAt = date
        presentedCount += 1
        let key = intervention.deduplicationKey
        if deliveredDeduplicationKeys.insert(key).inserted {
            deliveryOrder.append(key)
        }
        while deliveryOrder.count > historyLimit {
            deliveredDeduplicationKeys.remove(deliveryOrder.removeFirst())
        }
    }
}

/// Final fail-closed gate after model evaluation. Its defaults require high confidence, enforce
/// a sixty-second global cooldown, and suppress repeated issues within the current watch session.
struct InterventionPolicy: Equatable, Sendable {
    static let defaultMinimumConfidence = 0.95
    static let defaultCooldown: TimeInterval = 60

    let minimumConfidence: Double
    let cooldown: TimeInterval
    let duplicateHistoryLimit: Int
    private(set) var state: InterventionState

    init(
        minimumConfidence: Double = InterventionPolicy.defaultMinimumConfidence,
        cooldown: TimeInterval = InterventionPolicy.defaultCooldown,
        duplicateHistoryLimit: Int = 128,
        state: InterventionState = InterventionState()
    ) {
        self.minimumConfidence = minimumConfidence.isFinite && (0...1).contains(minimumConfidence)
            ? minimumConfidence : InterventionPolicy.defaultMinimumConfidence
        self.cooldown = cooldown.isFinite && cooldown >= 0
            ? cooldown : InterventionPolicy.defaultCooldown
        self.duplicateHistoryLimit = max(1, duplicateHistoryLimit)
        self.state = state
    }

    mutating func admit(_ verdict: InterventionVerdict, at date: Date) -> Intervention? {
        guard case .intervene(let intervention) = verdict,
              intervention.confidence >= minimumConfidence,
              !state.hasDelivered(intervention) else { return nil }

        if let lastPresentedAt = state.lastPresentedAt,
           date.timeIntervalSince(lastPresentedAt) < cooldown {
            return nil
        }
        if let action = intervention.suggestedAction,
           intervention.source(for: action) == nil {
            return nil
        }

        state.record(intervention, at: date, historyLimit: duplicateHistoryLimit)
        return intervention
    }

    mutating func reset() {
        state.reset()
    }
}

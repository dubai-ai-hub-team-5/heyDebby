import Foundation

enum GroundTruthValidationError: Error, Equatable {
    case invalidScenario
    case invalidFact
    case invalidSources
    case duplicateIdentifier
    case unknownSource
}

/// One authoritative claim and the trusted source identifiers that support it.
struct GroundTruthFact: Equatable, Hashable, Sendable {
    let id: SourceID
    let statement: String
    let sourceIDs: [SourceID]

    init(id: SourceID, statement: String, sourceIDs: [SourceID]) throws {
        let statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty, statement.utf8.count <= 1_000,
              !statement.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GroundTruthValidationError.invalidFact }
        guard (1...8).contains(sourceIDs.count), Set(sourceIDs).count == sourceIDs.count else {
            throw GroundTruthValidationError.invalidSources
        }
        self.id = id
        self.statement = statement
        self.sourceIDs = sourceIDs
    }
}

/// A point-in-time set of application-trusted facts. Source locations remain out-of-band from
/// model output; only their opaque IDs and display titles are included in evaluator prompts.
struct GroundTruthEvidence: Equatable, Sendable {
    let scenarioID: SourceID
    let scenario: String
    let facts: [GroundTruthFact]
    let sources: [SourceReference]

    init(
        scenarioID: SourceID,
        scenario: String,
        facts: [GroundTruthFact],
        sources: [SourceReference]
    ) throws {
        let scenario = scenario.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scenario.isEmpty, scenario.utf8.count <= 500,
              !scenario.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GroundTruthValidationError.invalidScenario }
        guard !facts.isEmpty, facts.count <= 32, !sources.isEmpty, sources.count <= 32 else {
            throw GroundTruthValidationError.invalidSources
        }
        guard Set(facts.map(\.id)).count == facts.count,
              Set(sources.map(\.id)).count == sources.count else {
            throw GroundTruthValidationError.duplicateIdentifier
        }

        let trustedSourceIDs = Set(sources.map(\.id))
        guard facts.allSatisfy({ Set($0.sourceIDs).isSubset(of: trustedSourceIDs) }) else {
            throw GroundTruthValidationError.unknownSource
        }

        self.scenarioID = scenarioID
        self.scenario = scenario
        self.facts = facts
        self.sources = sources
    }
}

/// Supplies authoritative context independently from the model that inspects the screen.
/// Implementations may return a static snapshot or fetch workspace data directly over native HTTP.
protocol GroundTruthProvider: Sendable {
    func evidence() async throws -> GroundTruthEvidence
}

/// Fixed evidence for the investor-update Google Workspace scenario. The sheet URL is supplied by
/// trusted application configuration and is validated as HTTPS before this provider can be created.
struct InvestorGoogleWorkspaceGroundTruthProvider: GroundTruthProvider, Sendable {
    static let q3CloseSheetSourceID = SourceID(rawValue: "google-workspace.q3-close-sheet")!
    static let q3RevenueFactID = SourceID(rawValue: "q3-revenue.final")!
    static let scenarioID = SourceID(rawValue: "investor-update.google-workspace")!
    static let q3RevenueUSD = 2_400_000

    private let snapshot: GroundTruthEvidence

    init(q3CloseSheetURL: URL) throws {
        let source = try SourceReference(
            id: Self.q3CloseSheetSourceID,
            title: "Q3 Close Sheet (Google Sheets)",
            httpsURL: q3CloseSheetURL
        )
        let fact = try GroundTruthFact(
            id: Self.q3RevenueFactID,
            statement: "The finalized Q3 close sheet reports Q3 revenue as USD 2,400,000 ($2.4M).",
            sourceIDs: [source.id]
        )
        snapshot = try GroundTruthEvidence(
            scenarioID: Self.scenarioID,
            scenario: "Reviewing a visible investor update drafted in Google Workspace against the finalized Q3 close.",
            facts: [fact],
            sources: [source]
        )
    }

    init(q3CloseSheetURLString: String) throws {
        guard let url = URL(string: q3CloseSheetURLString) else {
            throw SourceReferenceValidationError.invalidHTTPSURL
        }
        try self.init(q3CloseSheetURL: url)
    }

    func evidence() async throws -> GroundTruthEvidence {
        snapshot
    }
}

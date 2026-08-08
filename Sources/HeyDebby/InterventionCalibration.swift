import Foundation

struct InterventionCalibrationManifest: Decodable {
    let fixtures: [InterventionCalibrationFixture]
}

struct InterventionCalibrationFixture: Decodable {
    let image: String
    let expectedIntervention: Bool

    private enum CodingKeys: String, CodingKey {
        case image
        case expectedIntervention = "expected_intervention"
    }
}

struct InterventionCalibrationSummary: Codable, Equatable {
    var truePositive = 0
    var falsePositive = 0
    var trueNegative = 0
    var falseNegative = 0

    var total: Int { truePositive + falsePositive + trueNegative + falseNegative }
    var precision: Double {
        let denominator = truePositive + falsePositive
        return denominator == 0 ? 0 : Double(truePositive) / Double(denominator)
    }
    var recall: Double {
        let denominator = truePositive + falseNegative
        return denominator == 0 ? 0 : Double(truePositive) / Double(denominator)
    }
    var falsePositiveRate: Double {
        let denominator = falsePositive + trueNegative
        return denominator == 0 ? 0 : Double(falsePositive) / Double(denominator)
    }

    mutating func record(expected: Bool, observed: Bool) {
        switch (expected, observed) {
        case (true, true): truePositive += 1
        case (false, true): falsePositive += 1
        case (false, false): trueNegative += 1
        case (true, false): falseNegative += 1
        }
    }
}

enum InterventionCalibrationRunner {
    static func run(
        manifestURL: URL,
        evaluator: any InterventionEvaluator,
        evidence: GroundTruthEvidence
    ) async throws -> InterventionCalibrationSummary {
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(InterventionCalibrationManifest.self, from: data)
        var summary = InterventionCalibrationSummary()
        for fixture in manifest.fixtures {
            try Task.checkCancellation()
            let imageURL = manifestURL.deletingLastPathComponent().appendingPathComponent(fixture.image)
            let imageData = try Data(contentsOf: imageURL)
            let frame = WatchedFrame(imageData: imageData)
            let verdict = try await evaluator.evaluate(frame: frame, evidence: evidence)
            summary.record(
                expected: fixture.expectedIntervention,
                observed: verdict.proposedIntervention != nil
            )
        }
        return summary
    }
}

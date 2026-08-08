import Foundation
import XCTest
@testable import HeyDebby

final class InterventionTests: XCTestCase {
    private func source() throws -> SourceReference {
        try SourceReference(
            id: SourceID(rawValue: "google-workspace.q3-close-sheet")!,
            title: "Q3 close sheet",
            httpsURL: URL(string: "https://docs.google.com/spreadsheets/d/demo")!
        )
    }

    func testStrictInterventionResolvesTrustedSourceAndAnnotation() throws {
        let source = try source()
        let json = """
        {"verdict":"intervene","confidence":0.99,"title":"Revenue mismatch","message":"That's 2.4 million, not 4.2 million","annotation":{"x":0.62,"y":0.38,"label":"Revenue figure"},"source_ids":["google-workspace.q3-close-sheet"],"suggested_action":{"type":"open_source","source_id":"google-workspace.q3-close-sheet"}}
        """
        let verdict = try InterventionVerdict.decodeStrictJSON(json, trustedSources: [source])
        guard case .intervene(let intervention) = verdict else {
            return XCTFail("Expected an intervention")
        }
        XCTAssertEqual(intervention.sources, [source])
        XCTAssertEqual(intervention.annotation, try InterventionAnnotation(x: 0.62, y: 0.38, label: "Revenue figure"))
    }

    func testStrictInterventionRejectsUnknownSource() throws {
        let json = """
        {"verdict":"intervene","confidence":0.99,"title":"Revenue mismatch","message":"Wrong value","annotation":{"x":0.5,"y":0.5,"label":"Revenue"},"source_ids":["unknown.source"],"suggested_action":null}
        """
        XCTAssertThrowsError(try InterventionVerdict.decodeStrictJSON(json, trustedSources: [try source()]))
    }

    func testProviderAdaptersKeepKeysOutOfURLs() throws {
        let input = DirectHTTPInterventionInput(
            systemPrompt: "system",
            userPrompt: "user",
            imageData: Data([1, 2, 3]),
            imageMIMEType: "image/jpeg"
        )
        let openAI = try OpenAIInterventionAdapter(apiKey: "secret", model: "model")
            .makeRequest(for: input)
        XCTAssertNil(openAI.url?.query)
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer secret")

        let anthropic = try AnthropicInterventionAdapter(apiKey: "secret", model: "model")
            .makeRequest(for: input)
        XCTAssertNil(anthropic.url?.query)
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "secret")

        let gemini = try GeminiInterventionAdapter(apiKey: "secret", model: "model")
            .makeRequest(for: input)
        XCTAssertNil(gemini.url?.query)
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
    }

    func testCalibrationSummaryTracksConfusionMatrix() {
        var summary = InterventionCalibrationSummary()
        summary.record(expected: true, observed: true)
        summary.record(expected: false, observed: true)
        summary.record(expected: false, observed: false)
        summary.record(expected: true, observed: false)
        XCTAssertEqual(summary.truePositive, 1)
        XCTAssertEqual(summary.falsePositive, 1)
        XCTAssertEqual(summary.trueNegative, 1)
        XCTAssertEqual(summary.falseNegative, 1)
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.precision, 0.5)
        XCTAssertEqual(summary.recall, 0.5)
        XCTAssertEqual(summary.falsePositiveRate, 0.5)
    }

    func testInterventionPolicyIsConservativeAndRateLimited() throws {
        let source = try source()
        let annotation = try InterventionAnnotation(x: 0.5, y: 0.5, label: "Revenue")
        let low = try Intervention(
            title: "Low confidence",
            message: "Maybe wrong",
            confidence: 0.94,
            annotation: annotation,
            sources: [source]
        )
        var policy = InterventionPolicy()
        XCTAssertNil(policy.admit(.intervene(low), at: Date(timeIntervalSince1970: 0)))

        let first = try Intervention(
            title: "First mismatch",
            message: "Wrong",
            confidence: 0.99,
            annotation: annotation,
            sources: [source]
        )
        XCTAssertNotNil(policy.admit(.intervene(first), at: Date(timeIntervalSince1970: 0)))

        let second = try Intervention(
            title: "Second mismatch",
            message: "Also wrong",
            confidence: 0.99,
            annotation: annotation,
            sources: [source]
        )
        XCTAssertNil(policy.admit(.intervene(second), at: Date(timeIntervalSince1970: 30)))
        XCTAssertNotNil(policy.admit(.intervene(second), at: Date(timeIntervalSince1970: 61)))
    }
}

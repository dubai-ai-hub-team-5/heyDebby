import Foundation
import XCTest
@testable import HeyDebby

final class FoundationTests: XCTestCase {
    func testCaptureDownscalingPreservesAspectRatio() {
        XCTAssertEqual(
            Capture.downscaledDimensions(width: 5120, height: 2880, maximumLongEdge: 1280),
            Capture.PixelDimensions(width: 1280, height: 720)
        )
        XCTAssertEqual(
            Capture.downscaledDimensions(width: 800, height: 600, maximumLongEdge: 1280),
            Capture.PixelDimensions(width: 800, height: 600)
        )
    }

    func testFrameChangeThreshold() {
        XCTAssertFalse(FrameChangePolicy.interventionWatch.decision(distance: 0.01).didChange)
        XCTAssertTrue(FrameChangePolicy.interventionWatch.decision(distance: 0.025).didChange)
    }

    func testLegacySecretMigrationVerifiesBeforeRemoval() throws {
        let legacy = InMemoryLegacySecretStore(values: ["apiKey": "secret"])
        let destination = InMemorySecretStore()
        let result = try LegacySecretMigration.migrate(
            LegacySecretMapping(legacyKey: "apiKey", secretKey: .anthropic),
            from: legacy,
            to: destination
        )
        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(try destination.value(for: .anthropic), "secret")
        XCTAssertNil(try legacy.value(forLegacyKey: "apiKey"))
    }

    func testPointerFlightStartsAndEndsAtRequestedPoints() {
        let path = PointerFlightPath(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 300, y: 400))
        XCTAssertEqual(path.point(at: 0), CGPoint(x: 10, y: 20))
        XCTAssertEqual(path.point(at: 1), CGPoint(x: 300, y: 400))
        XCTAssertEqual(path.scale(at: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(path.scale(at: 1), 1, accuracy: 0.0001)
    }

    func testDemoPreflightReportsMissingConfiguration() {
        let suite = "DemoPreflightTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let result = DemoConfiguration.preflight(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        XCTAssertFalse(result.isReady)
        XCTAssertFalse(result.failures.isEmpty)
    }

    func testNetworkSessionsDoNotPersistCookiesOrCache() {
        let configuration = NetworkSession.configuration(for: .api)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
}

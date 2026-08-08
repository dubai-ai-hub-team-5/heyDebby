import Foundation

struct DemoConfiguration: Equatable {
    let scenarioID: String
    let q3CloseSheetURL: URL
    let slideURL: URL?
    let handoffURL: URL?

    static func load(defaults: UserDefaults = .standard) throws -> DemoConfiguration {
        let sourceText = defaults.string(forKey: "q3CloseSheetURL") ?? ""
        guard let source = URL(string: sourceText), SourceReference.isValidHTTPSURL(source) else {
            throw DemoConfigurationError.missingSource
        }
        let slide = defaults.string(forKey: "demoSlideURL")
            .flatMap(URL.init(string:))
        let handoff = defaults.string(forKey: "demoHandoffURL")
            .flatMap(URL.init(string:))
        if let slide, !SourceReference.isValidHTTPSURL(slide) {
            throw DemoConfigurationError.invalidSlide
        }
        if let handoff, !SourceReference.isValidHTTPSURL(handoff) {
            throw DemoConfigurationError.invalidHandoff
        }
        return DemoConfiguration(
            scenarioID: "investor-revenue",
            q3CloseSheetURL: source,
            slideURL: slide,
            handoffURL: handoff
        )
    }

    static func applyLaunchArguments(
        _ arguments: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard
    ) {
        guard let index = arguments.firstIndex(of: "--demo-scenario"),
              arguments.indices.contains(index + 1),
              arguments[index + 1] == "investor-revenue" else { return }
        defaults.set(true, forKey: "demoModeEnabled")
        defaults.set(true, forKey: "watchModeEnabled")
    }
}

struct DemoPreflightResult: Equatable {
    let failures: [String]
    var isReady: Bool { failures.isEmpty }
}

extension DemoConfiguration {
    static func preflight(
        defaults: UserDefaults = .standard,
        secretStore: SecretStoring = SecretStore.shared
    ) -> DemoPreflightResult {
        var failures: [String] = []
        let configuration: DemoConfiguration?
        do {
            configuration = try load(defaults: defaults)
        } catch {
            configuration = nil
            failures.append(error.localizedDescription)
        }
        if configuration?.slideURL == nil { failures.append("Google Slides URL is missing") }
        if configuration?.handoffURL == nil { failures.append("Deterministic handoff URL is missing") }
        let handoffToken = (try? secretStore.value(for: .demoHandoff)) ?? ""
        if handoffToken.isEmpty { failures.append("Deterministic handoff token is missing") }
        let hasDirectModelKey = [SecretKey.openAI, .anthropic, .gemini].contains {
            !((try? secretStore.value(for: $0)) ?? "").isEmpty
                || $0.environmentVariableNames.contains {
                    !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
                }
        }
        if !defaults.bool(forKey: "demoModeEnabled") && !hasDirectModelKey {
            failures.append("No direct vision API key is configured")
        }
        return DemoPreflightResult(failures: failures)
    }
}

enum DemoConfigurationError: Error, LocalizedError {
    case missingSource
    case invalidSlide
    case invalidHandoff

    var errorDescription: String? {
        switch self {
        case .missingSource: return "The Q3 close Google Sheet URL is missing or invalid"
        case .invalidSlide: return "The Google Slides URL is invalid"
        case .invalidHandoff: return "The deterministic handoff URL is invalid"
        }
    }
}

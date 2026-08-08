import AVFoundation
import Foundation

/// Whether a provider can be selected right now. Auto mode can inspect this without
/// knowing how an individual provider is configured.
enum TranscriptionProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Provider facts used by settings and automatic provider selection. A larger automatic
/// selection priority wins when more than one provider is available.
struct TranscriptionProviderMetadata: Equatable, Sendable {
    let identifier: String
    let displayName: String
    let availability: TranscriptionProviderAvailability
    let automaticSelectionPriority: Int
    let requiresSpeechRecognitionPermission: Bool
    let requiresNetwork: Bool
    let supportsContextualKeyterms: Bool

    var isAvailable: Bool { availability.isAvailable }
    var unavailableReason: String? { availability.unavailableReason }
}

typealias TranscriptionPartialHandler = (String) -> Void
typealias TranscriptionFinalHandler = (String) -> Void
typealias TranscriptionErrorHandler = (Error) -> Void

/// One recording. Implementations accept buffers until `finalize()` or `cancel()` and
/// produce at most one terminal callback (`onFinal` or `onError`).
protocol TranscriptionSession: AnyObject {
    /// The longest callers should keep a finalizing recording alive before applying their
    /// own safety fallback. Providers also enforce their own deadline.
    var finalizationTimeout: TimeInterval { get }

    func append(_ audioBuffer: AVAudioPCMBuffer)
    func finalize()
    func cancel()
}

/// Creates independent recording sessions while retaining provider-wide resources such as
/// a shared networking session.
protocol TranscriptionProvider: AnyObject {
    var metadata: TranscriptionProviderMetadata { get }

    func startSession(
        contextualKeyterms: [String],
        onPartial: @escaping TranscriptionPartialHandler,
        onFinal: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) async throws -> any TranscriptionSession
}

extension TranscriptionProvider {
    var displayName: String { metadata.displayName }
    var isAvailable: Bool { metadata.isAvailable }
    var isConfigured: Bool { metadata.isAvailable }
    var unavailableExplanation: String? { metadata.unavailableReason }
    var requiresSpeechRecognitionPermission: Bool {
        metadata.requiresSpeechRecognitionPermission
    }

    func startSession(
        onPartial: @escaping TranscriptionPartialHandler,
        onFinal: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) async throws -> any TranscriptionSession {
        try await startSession(
            contextualKeyterms: [],
            onPartial: onPartial,
            onFinal: onFinal,
            onError: onError
        )
    }

    /// Naming-compatible entry point for integration with existing streaming call sites.
    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping TranscriptionPartialHandler,
        onFinalTranscriptReady: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) async throws -> any TranscriptionSession {
        try await startSession(
            contextualKeyterms: keyterms,
            onPartial: onTranscriptUpdate,
            onFinal: onFinalTranscriptReady,
            onError: onError
        )
    }
}

extension TranscriptionSession {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { finalizationTimeout }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        append(audioBuffer)
    }

    func requestFinalTranscript() {
        finalize()
    }
}

import AVFoundation
import Foundation
import Speech

struct AppleSpeechTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class AppleSpeechTranscriptionProvider: TranscriptionProvider {
    private static let fallbackLocale = Locale(identifier: "en-US")

    private let preferredLocale: Locale
    private let callbackQueue: DispatchQueue
    private let sessionFinalizationTimeout: TimeInterval

    init(
        preferredLocale: Locale = .autoupdatingCurrent,
        finalizationTimeout: TimeInterval = 2.0,
        callbackQueue: DispatchQueue = .main
    ) {
        self.preferredLocale = preferredLocale
        self.sessionFinalizationTimeout = max(0.1, finalizationTimeout)
        self.callbackQueue = callbackQueue
    }

    var metadata: TranscriptionProviderMetadata {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()

        if authorizationStatus == .denied {
            return makeMetadata(
                availability: .unavailable(reason: "Speech recognition permission is denied.")
            )
        }

        if authorizationStatus == .restricted {
            return makeMetadata(
                availability: .unavailable(reason: "Speech recognition is restricted on this Mac.")
            )
        }

        guard let speechRecognizer = Self.makeBestAvailableRecognizer(
            preferredLocale: preferredLocale
        ) else {
            return makeMetadata(
                availability: .unavailable(reason: "Apple Speech recognition is currently unavailable.")
            )
        }

        return makeMetadata(
            availability: .available,
            requiresNetwork: !speechRecognizer.supportsOnDeviceRecognition
        )
    }

    func startSession(
        contextualKeyterms: [String],
        onPartial: @escaping TranscriptionPartialHandler,
        onFinal: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) async throws -> any TranscriptionSession {
        try Task.checkCancellation()

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            throw AppleSpeechTranscriptionProviderError(
                message: "Speech recognition permission has not been requested yet."
            )
        case .denied:
            throw AppleSpeechTranscriptionProviderError(
                message: "Speech recognition permission is denied."
            )
        case .restricted:
            throw AppleSpeechTranscriptionProviderError(
                message: "Speech recognition is restricted on this Mac."
            )
        @unknown default:
            throw AppleSpeechTranscriptionProviderError(
                message: "Speech recognition authorization could not be determined."
            )
        }

        guard let speechRecognizer = Self.makeBestAvailableRecognizer(
            preferredLocale: preferredLocale
        ) else {
            throw AppleSpeechTranscriptionProviderError(
                message: "Apple Speech recognition is currently unavailable."
            )
        }

        return AppleSpeechTranscriptionSession(
            speechRecognizer: speechRecognizer,
            contextualKeyterms: Self.normalizedKeyterms(contextualKeyterms),
            finalizationTimeout: sessionFinalizationTimeout,
            callbackQueue: callbackQueue,
            onPartial: onPartial,
            onFinal: onFinal,
            onError: onError
        )
    }

    private func makeMetadata(
        availability: TranscriptionProviderAvailability,
        requiresNetwork: Bool = false
    ) -> TranscriptionProviderMetadata {
        TranscriptionProviderMetadata(
            identifier: "apple",
            displayName: "Apple Speech",
            availability: availability,
            automaticSelectionPriority: 10,
            requiresSpeechRecognitionPermission: true,
            requiresNetwork: requiresNetwork,
            supportsContextualKeyterms: true
        )
    }

    /// Prefer the user's locale, but do not let an unsupported regional recognizer make
    /// dictation fail when the broadly available US English recognizer can be used.
    private static func makeBestAvailableRecognizer(
        preferredLocale: Locale
    ) -> SFSpeechRecognizer? {
        var localeIdentifiers: [String] = []
        for locale in [preferredLocale, Locale.autoupdatingCurrent, fallbackLocale] {
            guard !localeIdentifiers.contains(locale.identifier) else { continue }
            localeIdentifiers.append(locale.identifier)
        }

        for localeIdentifier in localeIdentifiers {
            guard let speechRecognizer = SFSpeechRecognizer(
                locale: Locale(identifier: localeIdentifier)
            ) else {
                continue
            }

            if speechRecognizer.supportsOnDeviceRecognition || speechRecognizer.isAvailable {
                return speechRecognizer
            }
        }

        if let defaultRecognizer = SFSpeechRecognizer(),
           defaultRecognizer.supportsOnDeviceRecognition || defaultRecognizer.isAvailable {
            return defaultRecognizer
        }

        return nil
    }

    private static func normalizedKeyterms(_ keyterms: [String]) -> [String] {
        var seenKeyterms = Set<String>()
        var normalizedKeyterms: [String] = []

        for keyterm in keyterms {
            let normalizedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKeyterm.isEmpty else { continue }

            let comparisonKey = normalizedKeyterm.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seenKeyterms.insert(comparisonKey).inserted else { continue }

            normalizedKeyterms.append(normalizedKeyterm)
        }

        return normalizedKeyterms
    }
}

private final class AppleSpeechTranscriptionSession: TranscriptionSession {
    private enum State: Equatable {
        case recording
        case finalizing
        case terminated
    }

    let finalizationTimeout: TimeInterval

    private let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    private let callbackQueue: DispatchQueue
    private let onPartial: TranscriptionPartialHandler
    private let onFinal: TranscriptionFinalHandler
    private let onError: TranscriptionErrorHandler
    private let stateLock = NSRecursiveLock()
    private let finalizationTimerQueue = DispatchQueue(
        label: "com.heydebby.apple-speech.finalization"
    )

    private var recognitionTask: SFSpeechRecognitionTask?
    private var state: State = .recording
    private var latestRecognizedText = ""
    private var lastDeliveredPartialText = ""
    private var finalizationDeadlineWorkItem: DispatchWorkItem?

    init(
        speechRecognizer: SFSpeechRecognizer,
        contextualKeyterms: [String],
        finalizationTimeout: TimeInterval,
        callbackQueue: DispatchQueue,
        onPartial: @escaping TranscriptionPartialHandler,
        onFinal: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) {
        self.finalizationTimeout = finalizationTimeout
        self.callbackQueue = DispatchQueue(
            label: "com.heydebby.apple-speech.callbacks",
            target: callbackQueue
        )
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        recognitionRequest.contextualStrings = contextualKeyterms

        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest
        ) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func append(_ audioBuffer: AVAudioPCMBuffer) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard state == .recording else { return }
        // Append synchronously: buffers supplied by an AVAudioEngine tap are only guaranteed
        // to contain that tap's samples for the duration of the callback.
        recognitionRequest.append(audioBuffer)
    }

    func finalize() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard state == .recording else { return }
        state = .finalizing

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.handleFinalizationTimeout()
        }
        finalizationDeadlineWorkItem = deadlineWorkItem
        finalizationTimerQueue.asyncAfter(
            deadline: .now() + finalizationTimeout,
            execute: deadlineWorkItem
        )

        recognitionRequest.endAudio()
    }

    func cancel() {
        let taskToCancel: SFSpeechRecognitionTask?

        stateLock.lock()
        guard state != .terminated else {
            stateLock.unlock()
            return
        }

        let shouldEndAudio = state == .recording
        state = .terminated
        finalizationDeadlineWorkItem?.cancel()
        finalizationDeadlineWorkItem = nil
        if shouldEndAudio {
            recognitionRequest.endAudio()
        }
        taskToCancel = recognitionTask
        recognitionTask = nil
        stateLock.unlock()

        taskToCancel?.cancel()
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        var partialTextToDeliver: String?
        var finalTextToDeliver: String?
        var errorToDeliver: Error?
        var taskToCancel: SFSpeechRecognitionTask?

        stateLock.lock()
        guard state != .terminated else {
            stateLock.unlock()
            return
        }

        if let result {
            let recognizedText = result.bestTranscription.formattedString
            latestRecognizedText = recognizedText

            if recognizedText != lastDeliveredPartialText {
                lastDeliveredPartialText = recognizedText
                partialTextToDeliver = recognizedText
            }

            if result.isFinal {
                state = .terminated
                finalizationDeadlineWorkItem?.cancel()
                finalizationDeadlineWorkItem = nil
                recognitionTask = nil
                finalTextToDeliver = recognizedText
            }
        }

        if finalTextToDeliver == nil, let error {
            let wasFinalizing = state == .finalizing
            let trimmedLatestText = latestRecognizedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            state = .terminated
            finalizationDeadlineWorkItem?.cancel()
            finalizationDeadlineWorkItem = nil
            taskToCancel = recognitionTask
            recognitionTask = nil

            if wasFinalizing, !trimmedLatestText.isEmpty {
                finalTextToDeliver = trimmedLatestText
            } else {
                errorToDeliver = error
            }
        }
        stateLock.unlock()

        if let partialTextToDeliver {
            callbackQueue.async { [onPartial = self.onPartial] in
                onPartial(partialTextToDeliver)
            }
        }
        if let finalTextToDeliver {
            callbackQueue.async { [onFinal = self.onFinal] in
                onFinal(finalTextToDeliver)
            }
        } else if let errorToDeliver {
            callbackQueue.async { [onError = self.onError] in
                onError(errorToDeliver)
            }
        }

        taskToCancel?.cancel()
    }

    private func handleFinalizationTimeout() {
        let fallbackText: String
        let taskToCancel: SFSpeechRecognitionTask?

        stateLock.lock()
        guard state == .finalizing else {
            stateLock.unlock()
            return
        }

        state = .terminated
        fallbackText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        finalizationDeadlineWorkItem = nil
        taskToCancel = recognitionTask
        recognitionTask = nil
        stateLock.unlock()

        taskToCancel?.cancel()
        callbackQueue.async { [onFinal = self.onFinal] in
            onFinal(fallbackText)
        }
    }

    deinit {
        finalizationDeadlineWorkItem?.cancel()
        recognitionTask?.cancel()
    }
}

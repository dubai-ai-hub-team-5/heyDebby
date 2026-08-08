import AVFoundation
import Foundation

struct AssemblyAITranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Bring-your-own-key realtime transcription. The key is retained privately by the provider,
/// placed only in the websocket Authorization header, and never included in URLs or logging.
final class AssemblyAITranscriptionProvider: TranscriptionProvider {
    static let defaultWebSocketEndpoint = URL(
        string: "wss://streaming.assemblyai.com/v3/ws"
    )!

    private let apiKey: String
    private let webSocketEndpoint: URL
    private let callbackQueue: DispatchQueue
    private let connectionTimeout: TimeInterval
    private let forceEndpointGracePeriod: TimeInterval
    private let sessionFinalizationTimeout: TimeInterval

    /// One provider-owned URLSession lives across every recording. Each call to
    /// `startSession` still creates a new URLSessionWebSocketTask.
    private let webSocketURLSession: URLSession

    init(
        apiKey: String,
        webSocketEndpoint: URL = AssemblyAITranscriptionProvider.defaultWebSocketEndpoint,
        urlSessionConfiguration: URLSessionConfiguration = NetworkSession.configuration(for: .realtime),
        connectionTimeout: TimeInterval = 10.0,
        forceEndpointGracePeriod: TimeInterval = 1.4,
        finalizationTimeout: TimeInterval = 2.8,
        callbackQueue: DispatchQueue = .main
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.webSocketEndpoint = webSocketEndpoint
        self.callbackQueue = callbackQueue
        self.connectionTimeout = max(0.1, connectionTimeout)
        let clampedForceEndpointGracePeriod = max(0.1, forceEndpointGracePeriod)
        self.forceEndpointGracePeriod = clampedForceEndpointGracePeriod
        self.sessionFinalizationTimeout = max(
            max(0.1, finalizationTimeout),
            clampedForceEndpointGracePeriod
        )
        self.webSocketURLSession = URLSession(configuration: urlSessionConfiguration)
    }

    var metadata: TranscriptionProviderMetadata {
        let availability: TranscriptionProviderAvailability

        if apiKey.isEmpty {
            availability = .unavailable(reason: "An AssemblyAI API key is required.")
        } else if !Self.isSupportedWebSocketEndpoint(webSocketEndpoint) {
            availability = .unavailable(reason: "The AssemblyAI websocket endpoint is invalid.")
        } else {
            availability = .available
        }

        return TranscriptionProviderMetadata(
            identifier: "assemblyai",
            displayName: "AssemblyAI",
            availability: availability,
            automaticSelectionPriority: 100,
            requiresSpeechRecognitionPermission: false,
            requiresNetwork: true,
            supportsContextualKeyterms: true
        )
    }

    func startSession(
        contextualKeyterms: [String],
        onPartial: @escaping TranscriptionPartialHandler,
        onFinal: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) async throws -> any TranscriptionSession {
        try Task.checkCancellation()

        guard metadata.isAvailable else {
            throw AssemblyAITranscriptionProviderError(
                message: metadata.unavailableReason ?? "AssemblyAI is unavailable."
            )
        }

        let webSocketURL = try Self.makeWebSocketURL(
            endpoint: webSocketEndpoint,
            contextualKeyterms: contextualKeyterms
        )
        var webSocketRequest = URLRequest(url: webSocketURL)
        webSocketRequest.timeoutInterval = connectionTimeout
        webSocketRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let webSocketTask = webSocketURLSession.webSocketTask(with: webSocketRequest)
        let transcriptionSession = AssemblyAITranscriptionSession(
            providerLifetime: self,
            webSocketTask: webSocketTask,
            connectionTimeout: connectionTimeout,
            forceEndpointGracePeriod: forceEndpointGracePeriod,
            finalizationTimeout: sessionFinalizationTimeout,
            callbackQueue: callbackQueue,
            onPartial: onPartial,
            onFinal: onFinal,
            onError: onError
        )

        do {
            try await transcriptionSession.open()
            try Task.checkCancellation()
            return transcriptionSession
        } catch {
            transcriptionSession.cancel()
            throw error
        }
    }

    static func makeWebSocketURL(
        endpoint: URL = defaultWebSocketEndpoint,
        contextualKeyterms: [String]
    ) throws -> URL {
        guard isSupportedWebSocketEndpoint(endpoint),
              var webSocketURLComponents = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
              ) else {
            throw AssemblyAITranscriptionProviderError(
                message: "The AssemblyAI websocket endpoint is invalid."
            )
        }

        var queryItems = (webSocketURLComponents.queryItems ?? []).filter { queryItem in
            !["sample_rate", "encoding", "format_turns", "speech_model", "keyterms_prompt"]
                .contains(queryItem.name)
        }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro")
        ])

        let normalizedKeyterms = normalizedKeyterms(contextualKeyterms)
        if !normalizedKeyterms.isEmpty {
            let keytermsData: Data
            do {
                keytermsData = try JSONSerialization.data(withJSONObject: normalizedKeyterms)
            } catch {
                throw AssemblyAITranscriptionProviderError(
                    message: "Contextual transcription keyterms could not be encoded."
                )
            }

            guard let keytermsJSONString = String(data: keytermsData, encoding: .utf8) else {
                throw AssemblyAITranscriptionProviderError(
                    message: "Contextual transcription keyterms could not be encoded."
                )
            }
            queryItems.append(
                URLQueryItem(name: "keyterms_prompt", value: keytermsJSONString)
            )
        }

        webSocketURLComponents.queryItems = queryItems
        guard let webSocketURL = webSocketURLComponents.url else {
            throw AssemblyAITranscriptionProviderError(
                message: "The AssemblyAI websocket URL could not be created."
            )
        }
        return webSocketURL
    }

    private static func isSupportedWebSocketEndpoint(_ endpoint: URL) -> Bool {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" else {
            return false
        }
        return endpoint.host != nil
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
            if normalizedKeyterms.count == 100 { break }
        }

        return normalizedKeyterms
    }

    deinit {
        webSocketURLSession.invalidateAndCancel()
    }
}

private final class AssemblyAITranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private struct MessageEnvelope: Decodable {
        let type: String
    }

    private struct TurnMessage: Decodable {
        let transcript: String?
        let turnOrder: Int?
        let endOfTurn: Bool?
        let turnIsFormatted: Bool?

        private enum CodingKeys: String, CodingKey {
            case transcript
            case turnOrder = "turn_order"
            case endOfTurn = "end_of_turn"
            case turnIsFormatted = "turn_is_formatted"
        }
    }

    private struct ServerErrorMessage: Decodable {
        let error: String?
        let message: String?
    }

    private struct StoredTurnTranscript {
        var transcriptText: String
        var isEndOfTurn: Bool
        var isFormatted: Bool
    }

    private struct PendingOutboundMessage {
        let message: URLSessionWebSocketTask.Message
        let onSent: (() -> Void)?
    }

    private enum Lifecycle: Equatable {
        case connecting
        case streaming
        case finalizing
        case completed
        case failed
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled:
                return true
            case .connecting, .streaming, .finalizing:
                return false
            }
        }
    }

    let finalizationTimeout: TimeInterval

    // Keeping the provider alive keeps its one long-lived URLSession valid for this task.
    private let providerLifetime: AssemblyAITranscriptionProvider
    private let webSocketTask: URLSessionWebSocketTask
    private let connectionTimeout: TimeInterval
    private let forceEndpointGracePeriod: TimeInterval
    private let callbackQueue: DispatchQueue
    private let onPartial: TranscriptionPartialHandler
    private let onFinal: TranscriptionFinalHandler
    private let onError: TranscriptionErrorHandler
    private let audioConverter = PCM16AudioConverter()

    private let stateQueue = DispatchQueue(label: "com.heydebby.assemblyai.state")
    private let outboundQueue = DispatchQueue(label: "com.heydebby.assemblyai.outbound")
    private let audioSubmissionLock = NSLock()

    // Accessed only while `audioSubmissionLock` is held. It closes synchronously so a
    // ForceEndpoint message is always queued after every accepted audio buffer.
    private var acceptsAudioBuffers = true

    // State queue properties.
    private var lifecycle: Lifecycle = .connecting
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var connectionDeadlineWorkItem: DispatchWorkItem?
    private var finalizationDeadlineWorkItem: DispatchWorkItem?
    private var forceEndpointGraceDeadlineWorkItem: DispatchWorkItem?
    private var storedTurnTranscriptsByOrder: [Int: StoredTurnTranscript] = [:]
    private var inferredActiveTurnOrder: Int?
    private var lastEndedTurnOrder: Int?
    private var latestTranscriptText = ""
    private var lastDeliveredPartialText = ""

    // Outbound queue properties. Only one websocket send is active at a time, preserving
    // PCM buffer order and guaranteeing ForceEndpoint follows the final audio bytes.
    private var pendingOutboundMessages: [PendingOutboundMessage] = []
    private var isOutboundSendInFlight = false
    private var shouldCloseAfterDrainingOutboundMessages = false
    private var isOutboundClosed = false

    init(
        providerLifetime: AssemblyAITranscriptionProvider,
        webSocketTask: URLSessionWebSocketTask,
        connectionTimeout: TimeInterval,
        forceEndpointGracePeriod: TimeInterval,
        finalizationTimeout: TimeInterval,
        callbackQueue: DispatchQueue,
        onPartial: @escaping TranscriptionPartialHandler,
        onFinal: @escaping TranscriptionFinalHandler,
        onError: @escaping TranscriptionErrorHandler
    ) {
        self.providerLifetime = providerLifetime
        self.webSocketTask = webSocketTask
        self.connectionTimeout = connectionTimeout
        self.forceEndpointGracePeriod = forceEndpointGracePeriod
        self.finalizationTimeout = finalizationTimeout
        self.callbackQueue = DispatchQueue(
            label: "com.heydebby.assemblyai.callbacks",
            target: callbackQueue
        )
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
    }

    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                stateQueue.async {
                    guard self.lifecycle == .connecting else {
                        continuation.resume(
                            throwing: self.lifecycle == .cancelled
                                ? CancellationError()
                                : AssemblyAITranscriptionProviderError(
                                    message: "The AssemblyAI session could not be opened."
                                )
                        )
                        return
                    }
                    guard self.openContinuation == nil else {
                        continuation.resume(
                            throwing: AssemblyAITranscriptionProviderError(
                                message: "The AssemblyAI session is already opening."
                            )
                        )
                        return
                    }

                    self.openContinuation = continuation
                    self.scheduleConnectionDeadlineLocked()
                    self.webSocketTask.resume()
                    self.receiveNextMessageLocked()
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func append(_ audioBuffer: AVAudioPCMBuffer) {
        audioSubmissionLock.lock()
        guard acceptsAudioBuffers else {
            audioSubmissionLock.unlock()
            return
        }

        do {
            // Convert synchronously while the AVAudioEngine tap buffer is valid. The resulting
            // Data owns its samples and is safe to queue for network transmission.
            let pcm16AudioData = try audioConverter.convert(audioBuffer)
            if !pcm16AudioData.isEmpty {
                outboundQueue.async {
                    self.enqueueOutboundMessageLocked(.data(pcm16AudioData))
                }
            }
            audioSubmissionLock.unlock()
        } catch {
            audioSubmissionLock.unlock()
            reportFailure(error)
        }
    }

    func finalize() {
        audioSubmissionLock.lock()
        guard acceptsAudioBuffers else {
            audioSubmissionLock.unlock()
            return
        }
        acceptsAudioBuffers = false
        audioSubmissionLock.unlock()

        stateQueue.async {
            guard self.lifecycle == .streaming else { return }
            self.lifecycle = .finalizing
            self.scheduleFinalizationDeadlineLocked()
            self.enqueueControlMessage(type: "ForceEndpoint") { [weak self] in
                self?.stateQueue.async {
                    guard let self, self.lifecycle == .finalizing else { return }
                    self.scheduleForceEndpointGraceDeadlineLocked()
                }
            }
        }
    }

    func cancel() {
        closeAudioSubmission()

        stateQueue.async {
            guard !self.lifecycle.isTerminal else { return }
            self.lifecycle = .cancelled
            self.cancelDeadlinesLocked()
            self.resolveOpenContinuationLocked(with: .failure(CancellationError()))
            self.webSocketTask.cancel(with: .goingAway, reason: nil)
            self.closeOutboundImmediately()
        }
    }

    private func receiveNextMessageLocked() {
        guard !lifecycle.isTerminal else { return }

        webSocketTask.receive { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.lifecycle.isTerminal else { return }

                switch result {
                case .success(let message):
                    self.handleIncomingMessageLocked(message)
                case .failure(let error):
                    self.failLocked(error)
                }

                if !self.lifecycle.isTerminal {
                    self.receiveNextMessageLocked()
                }
            }
        }
    }

    private func handleIncomingMessageLocked(
        _ message: URLSessionWebSocketTask.Message
    ) {
        let messageData: Data
        switch message {
        case .string(let text):
            messageData = Data(text.utf8)
        case .data(let data):
            messageData = data
        @unknown default:
            return
        }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)
            switch envelope.type.lowercased() {
            case "begin":
                guard lifecycle == .connecting else { return }
                lifecycle = .streaming
                connectionDeadlineWorkItem?.cancel()
                connectionDeadlineWorkItem = nil
                resolveOpenContinuationLocked(with: .success(()))

            case "turn":
                let turnMessage = try JSONDecoder().decode(TurnMessage.self, from: messageData)
                handleTurnMessageLocked(turnMessage)

            case "termination":
                if lifecycle == .finalizing {
                    deliverFinalLocked(bestAvailableTranscriptLocked())
                } else if lifecycle == .connecting {
                    failLocked(
                        AssemblyAITranscriptionProviderError(
                            message: "AssemblyAI closed before the session became ready."
                        )
                    )
                } else if lifecycle == .streaming {
                    failLocked(
                        AssemblyAITranscriptionProviderError(
                            message: "AssemblyAI closed the active transcription session."
                        )
                    )
                }

            case "error":
                let serverError = try JSONDecoder().decode(
                    ServerErrorMessage.self,
                    from: messageData
                )
                failLocked(
                    AssemblyAITranscriptionProviderError(
                        message: serverError.error
                            ?? serverError.message
                            ?? "AssemblyAI returned an error."
                    )
                )

            default:
                break
            }
        } catch {
            failLocked(
                AssemblyAITranscriptionProviderError(
                    message: "AssemblyAI returned a malformed websocket message."
                )
            )
        }
    }

    private func handleTurnMessageLocked(_ turnMessage: TurnMessage) {
        guard lifecycle == .streaming || lifecycle == .finalizing else { return }

        let isFormatted = turnMessage.turnIsFormatted == true
        let isEndOfTurn = turnMessage.endOfTurn == true || isFormatted
        let turnOrder = resolvedTurnOrderLocked(
            explicitTurnOrder: turnMessage.turnOrder,
            isEndOfTurn: isEndOfTurn,
            isFormatted: isFormatted
        )
        let incomingTranscriptText = turnMessage.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingTurnTranscript = storedTurnTranscriptsByOrder[turnOrder]

        // Formatting messages intentionally replace the earlier unformatted turn. A late
        // unformatted update must never overwrite the formatted version.
        if existingTurnTranscript?.isFormatted == true, !isFormatted {
            return
        }

        let transcriptText = incomingTranscriptText.isEmpty
            ? (existingTurnTranscript?.transcriptText ?? "")
            : incomingTranscriptText

        if !transcriptText.isEmpty {
            storedTurnTranscriptsByOrder[turnOrder] = StoredTurnTranscript(
                transcriptText: transcriptText,
                isEndOfTurn: isEndOfTurn || existingTurnTranscript?.isEndOfTurn == true,
                isFormatted: isFormatted || existingTurnTranscript?.isFormatted == true
            )
        }

        if isEndOfTurn {
            lastEndedTurnOrder = turnOrder
            if inferredActiveTurnOrder == turnOrder {
                inferredActiveTurnOrder = nil
            }
        } else {
            inferredActiveTurnOrder = turnOrder
        }

        let fullTranscriptText = composeTranscriptLocked()
        latestTranscriptText = fullTranscriptText

        if !fullTranscriptText.isEmpty, fullTranscriptText != lastDeliveredPartialText {
            lastDeliveredPartialText = fullTranscriptText
            callbackQueue.async { [onPartial = self.onPartial] in
                onPartial(fullTranscriptText)
            }
        }
        // During explicit finalization, keep the grace window open even after an unformatted
        // endpoint. AssemblyAI may follow it with a formatted replacement for the same order.
    }

    private func resolvedTurnOrderLocked(
        explicitTurnOrder: Int?,
        isEndOfTurn: Bool,
        isFormatted: Bool
    ) -> Int {
        if let explicitTurnOrder { return explicitTurnOrder }
        if isFormatted, let lastEndedTurnOrder { return lastEndedTurnOrder }
        if let inferredActiveTurnOrder { return inferredActiveTurnOrder }

        let nextTurnOrder = (storedTurnTranscriptsByOrder.keys.max() ?? -1) + 1
        if !isEndOfTurn {
            inferredActiveTurnOrder = nextTurnOrder
        }
        return nextTurnOrder
    }

    private func composeTranscriptLocked() -> String {
        storedTurnTranscriptsByOrder
            .sorted { $0.key < $1.key }
            .map(\.value.transcriptText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func bestAvailableTranscriptLocked() -> String {
        let composedTranscript = composeTranscriptLocked()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !composedTranscript.isEmpty { return composedTranscript }
        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleConnectionDeadlineLocked() {
        connectionDeadlineWorkItem?.cancel()
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.lifecycle == .connecting else { return }
            self.failLocked(
                AssemblyAITranscriptionProviderError(
                    message: "Timed out while opening the AssemblyAI websocket."
                )
            )
        }
        connectionDeadlineWorkItem = deadlineWorkItem
        stateQueue.asyncAfter(
            deadline: .now() + connectionTimeout,
            execute: deadlineWorkItem
        )
    }

    private func scheduleFinalizationDeadlineLocked() {
        finalizationDeadlineWorkItem?.cancel()
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.lifecycle == .finalizing else { return }
            self.deliverFinalLocked(self.bestAvailableTranscriptLocked())
        }
        finalizationDeadlineWorkItem = deadlineWorkItem
        stateQueue.asyncAfter(
            deadline: .now() + finalizationTimeout,
            execute: deadlineWorkItem
        )
    }

    private func scheduleForceEndpointGraceDeadlineLocked() {
        forceEndpointGraceDeadlineWorkItem?.cancel()
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.lifecycle == .finalizing else { return }
            self.deliverFinalLocked(self.bestAvailableTranscriptLocked())
        }
        forceEndpointGraceDeadlineWorkItem = deadlineWorkItem
        stateQueue.asyncAfter(
            deadline: .now() + forceEndpointGracePeriod,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalLocked(_ transcriptText: String) {
        guard lifecycle == .finalizing else { return }
        lifecycle = .completed
        cancelDeadlinesLocked()
        closeAudioSubmission()

        let trimmedTranscriptText = transcriptText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        callbackQueue.async { [onFinal = self.onFinal] in
            onFinal(trimmedTranscriptText)
        }
        finishOutboundNormally()
    }

    private func reportFailure(_ error: Error) {
        stateQueue.async {
            self.failLocked(error)
        }
    }

    private func failLocked(_ error: Error) {
        guard !lifecycle.isTerminal else { return }

        if lifecycle == .finalizing {
            let fallbackTranscriptText = bestAvailableTranscriptLocked()
            if !fallbackTranscriptText.isEmpty {
                deliverFinalLocked(fallbackTranscriptText)
                webSocketTask.cancel(with: .goingAway, reason: nil)
                closeOutboundImmediately()
                return
            }
        }

        let wasConnecting = lifecycle == .connecting
        lifecycle = .failed
        cancelDeadlinesLocked()
        closeAudioSubmission()

        if wasConnecting {
            resolveOpenContinuationLocked(with: .failure(error))
        } else {
            callbackQueue.async { [onError = self.onError] in
                onError(error)
            }
        }

        webSocketTask.cancel(with: .goingAway, reason: nil)
        closeOutboundImmediately()
    }

    private func resolveOpenContinuationLocked(with result: Result<Void, Error>) {
        guard let openContinuation else { return }
        self.openContinuation = nil

        switch result {
        case .success:
            openContinuation.resume()
        case .failure(let error):
            openContinuation.resume(throwing: error)
        }
    }

    private func cancelDeadlinesLocked() {
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
        finalizationDeadlineWorkItem?.cancel()
        finalizationDeadlineWorkItem = nil
        forceEndpointGraceDeadlineWorkItem?.cancel()
        forceEndpointGraceDeadlineWorkItem = nil
    }

    private func closeAudioSubmission() {
        audioSubmissionLock.lock()
        acceptsAudioBuffers = false
        audioSubmissionLock.unlock()
    }

    private func enqueueControlMessage(
        type: String,
        onSent: (() -> Void)? = nil
    ) {
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: ["type": type]
        ), let jsonText = String(data: jsonData, encoding: .utf8) else {
            failLocked(
                AssemblyAITranscriptionProviderError(
                    message: "A websocket control message could not be encoded."
                )
            )
            return
        }

        outboundQueue.async {
            self.enqueueOutboundMessageLocked(.string(jsonText), onSent: onSent)
        }
    }

    private func enqueueOutboundMessageLocked(
        _ message: URLSessionWebSocketTask.Message,
        onSent: (() -> Void)? = nil
    ) {
        guard !isOutboundClosed else { return }
        pendingOutboundMessages.append(
            PendingOutboundMessage(message: message, onSent: onSent)
        )
        sendNextOutboundMessageLocked()
    }

    private func sendNextOutboundMessageLocked() {
        guard !isOutboundClosed, !isOutboundSendInFlight else { return }

        guard !pendingOutboundMessages.isEmpty else {
            if shouldCloseAfterDrainingOutboundMessages {
                isOutboundClosed = true
                webSocketTask.cancel(with: .normalClosure, reason: nil)
            }
            return
        }

        let nextPendingMessage = pendingOutboundMessages.removeFirst()
        isOutboundSendInFlight = true
        webSocketTask.send(nextPendingMessage.message) { [weak self] error in
            guard let self else { return }
            self.outboundQueue.async {
                guard !self.isOutboundClosed else { return }
                self.isOutboundSendInFlight = false

                if let error {
                    self.pendingOutboundMessages.removeAll()
                    self.isOutboundClosed = true
                    self.reportFailure(error)
                    return
                }

                nextPendingMessage.onSent?()
                self.sendNextOutboundMessageLocked()
            }
        }
    }

    private func finishOutboundNormally() {
        guard let terminateData = try? JSONSerialization.data(
            withJSONObject: ["type": "Terminate"]
        ), let terminateText = String(data: terminateData, encoding: .utf8) else {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
            return
        }

        outboundQueue.async {
            guard !self.isOutboundClosed else { return }
            self.pendingOutboundMessages.append(
                PendingOutboundMessage(message: .string(terminateText), onSent: nil)
            )
            self.shouldCloseAfterDrainingOutboundMessages = true
            self.sendNextOutboundMessageLocked()
        }
    }

    private func closeOutboundImmediately() {
        outboundQueue.async {
            self.pendingOutboundMessages.removeAll()
            self.shouldCloseAfterDrainingOutboundMessages = false
            self.isOutboundClosed = true
        }
    }

    deinit {
        connectionDeadlineWorkItem?.cancel()
        finalizationDeadlineWorkItem?.cancel()
        forceEndpointGraceDeadlineWorkItem?.cancel()
        webSocketTask.cancel(with: .goingAway, reason: nil)
    }
}

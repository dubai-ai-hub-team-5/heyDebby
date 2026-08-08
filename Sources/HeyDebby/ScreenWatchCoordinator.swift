import Foundation

/// Capture-domain-independent frame passed to intervention evaluators.
///
/// Integrations should provide a perceptual `visibleContentIdentifier` (for example, from a
/// downsampled luminance image). The convenience fallback fingerprints the encoded bytes, which
/// is exact but can treat compression noise as a visible change.
struct WatchedFrame: Equatable, Sendable {
    let imageData: Data
    let mimeType: String
    let visibleContentIdentifier: String

    init(
        imageData: Data,
        mimeType: String = "image/jpeg",
        visibleContentIdentifier: String? = nil
    ) {
        self.imageData = imageData
        let normalizedMIMEType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.mimeType = normalizedMIMEType.isEmpty ? "application/octet-stream" : normalizedMIMEType
        let suppliedIdentifier = visibleContentIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.visibleContentIdentifier = suppliedIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.byteFingerprint(imageData)
    }

    private static func byteFingerprint(_ data: Data) -> String {
        // FNV-1a is only a change token, never an authenticity primitive.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "bytes-\(data.count)-\(String(hash, radix: 16))"
    }
}

protocol WatchedFrameSource: Sendable {
    /// `nil` means there is currently no frame (for example, screen permission is unavailable).
    func captureFrame() async throws -> WatchedFrame?
}

protocol ScreenWatchClock: Sendable {
    func now() async -> Date
}

protocol ScreenWatchSleeper: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

struct SystemScreenWatchClock: ScreenWatchClock, Sendable {
    func now() async -> Date { Date() }
}

struct SystemScreenWatchSleeper: ScreenWatchSleeper, Sendable {
    func sleep(for interval: TimeInterval) async throws {
        let seconds = max(0, interval)
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let nanoseconds = UInt64(min(seconds, maximumSeconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Owns the proactive watch loop. One worker is retained until it has fully exited; a resume never
/// overlaps an evaluator that ignored cancellation from an older generation.
actor ScreenWatchCoordinator {
    enum Status: Equatable, Sendable {
        case stopped
        case running
        case paused
    }

    typealias InterventionCallback = @MainActor @Sendable (Intervention) -> Void
    typealias StatusCallback = @MainActor @Sendable (Status) -> Void
    typealias TimingCallback = @MainActor @Sendable (InterventionTiming) -> Void

    private let frameSource: any WatchedFrameSource
    private let evaluator: any InterventionEvaluator
    private let evidenceProvider: any GroundTruthProvider
    private let clock: any ScreenWatchClock
    private let sleeper: any ScreenWatchSleeper
    private let cadence: TimeInterval
    private let onIntervention: InterventionCallback?
    private let onStatusChange: StatusCallback?
    private let onTiming: TimingCallback?

    private(set) var status: Status = .stopped
    private(set) var policy: InterventionPolicy
    private var generation: UInt64 = 0
    private var workerSerial: UInt64 = 0
    private var activeWorkerSerial: UInt64?
    private var workerTask: Task<Void, Never>?
    private var lastEvaluatedVisibleContentIdentifier: String?

    init(
        frameSource: any WatchedFrameSource,
        evaluator: any InterventionEvaluator,
        evidenceProvider: any GroundTruthProvider,
        policy: InterventionPolicy = InterventionPolicy(),
        clock: any ScreenWatchClock = SystemScreenWatchClock(),
        sleeper: any ScreenWatchSleeper = SystemScreenWatchSleeper(),
        cadence: TimeInterval = 3,
        onIntervention: InterventionCallback? = nil,
        onStatusChange: StatusCallback? = nil,
        onTiming: TimingCallback? = nil
    ) {
        self.frameSource = frameSource
        self.evaluator = evaluator
        self.evidenceProvider = evidenceProvider
        self.policy = policy
        self.clock = clock
        self.sleeper = sleeper
        self.cadence = cadence.isFinite && cadence > 0 ? cadence : 3
        self.onIntervention = onIntervention
        self.onStatusChange = onStatusChange
        self.onTiming = onTiming
    }

    /// Starts a new watch session. The worker captures and evaluates before its first sleep.
    func start() async {
        guard status == .stopped else { return }
        generation &+= 1
        lastEvaluatedVisibleContentIdentifier = nil
        policy.reset()
        status = .running
        startWorkerIfNeeded()
        if let onStatusChange { await onStatusChange(.running) }
    }

    /// Cancels the current generation while retaining visible-change and duplicate memory.
    func pause() async {
        guard status == .running else { return }
        status = .paused
        generation &+= 1
        workerTask?.cancel()
        if let onStatusChange { await onStatusChange(.paused) }
    }

    /// Resumes immediately when no old worker remains. If an evaluator ignored cancellation, the
    /// old worker is allowed to exit first and then atomically hands off to the new generation.
    func resume() async {
        guard status == .paused else { return }
        status = .running
        generation &+= 1
        startWorkerIfNeeded()
        if let onStatusChange { await onStatusChange(.running) }
    }

    /// Ends the session and invalidates every result that could still arrive from an async call.
    func stop() async {
        guard status != .stopped else { return }
        status = .stopped
        generation &+= 1
        workerTask?.cancel()
        lastEvaluatedVisibleContentIdentifier = nil
        policy.reset()
        if let onStatusChange { await onStatusChange(.stopped) }
    }

    private func startWorkerIfNeeded() {
        guard status == .running, workerTask == nil else { return }
        workerSerial &+= 1
        let serial = workerSerial
        let workerGeneration = generation
        activeWorkerSerial = serial
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.runWorker(generation: workerGeneration)
            await self.workerFinished(serial: serial, generation: workerGeneration)
        }
    }

    private func workerFinished(serial: UInt64, generation workerGeneration: UInt64) {
        guard activeWorkerSerial == serial else { return }
        activeWorkerSerial = nil
        workerTask = nil
        if status == .running, generation != workerGeneration {
            // This is the resume/start handoff when cancelled work completed late. A same-
            // generation sleeper failure is not spun into an immediate retry loop.
            startWorkerIfNeeded()
        }
    }

    private func runWorker(generation workerGeneration: UInt64) async {
        var shouldSleep = false
        while isCurrent(workerGeneration) {
            if shouldSleep {
                do {
                    try await sleeper.sleep(for: cadence)
                } catch {
                    return
                }
                guard isCurrent(workerGeneration) else { return }
            }
            shouldSleep = true
            await captureAndEvaluate(generation: workerGeneration)
        }
    }

    private func captureAndEvaluate(generation workerGeneration: UInt64) async {
        let startedAt = Date()
        let frame: WatchedFrame?
        do {
            frame = try await frameSource.captureFrame()
        } catch {
            return
        }
        let capturedAt = Date()
        guard isCurrent(workerGeneration), let frame else { return }

        // Mark before external evaluation. A failed evaluator remains silent and is not hammered
        // every three seconds with identical private content; a genuinely changed frame retries.
        guard frame.visibleContentIdentifier != lastEvaluatedVisibleContentIdentifier else { return }
        lastEvaluatedVisibleContentIdentifier = frame.visibleContentIdentifier

        let evidence: GroundTruthEvidence
        do {
            evidence = try await evidenceProvider.evidence()
        } catch {
            return
        }
        let evidenceReadyAt = Date()
        guard isCurrent(workerGeneration) else { return }

        let verdict: InterventionVerdict
        do {
            verdict = try await evaluator.evaluate(frame: frame, evidence: evidence)
        } catch {
            // Evaluation is intentionally fail-silent and screen/model content is never logged.
            return
        }
        let evaluatedAt = Date()
        guard isCurrent(workerGeneration) else { return }

        let now = await clock.now()
        let intervention = policy.admit(verdict, at: now)
        if let onTiming {
            await onTiming(InterventionTiming(
                captureMilliseconds: Int(capturedAt.timeIntervalSince(startedAt) * 1_000),
                evidenceMilliseconds: Int(evidenceReadyAt.timeIntervalSince(capturedAt) * 1_000),
                modelMilliseconds: Int(evaluatedAt.timeIntervalSince(evidenceReadyAt) * 1_000),
                totalMilliseconds: Int(evaluatedAt.timeIntervalSince(startedAt) * 1_000),
                producedIntervention: intervention != nil
            ))
        }
        guard isCurrent(workerGeneration), let intervention else { return }
        if let onIntervention { await onIntervention(intervention) }
    }

    private func isCurrent(_ workerGeneration: UInt64) -> Bool {
        status == .running && generation == workerGeneration && !Task.isCancelled
    }
}

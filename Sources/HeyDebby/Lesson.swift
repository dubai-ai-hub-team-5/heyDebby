import Foundation

/// Plays beats in order, holding everything behind the sentence currently being spoken.
///
/// That wait is the whole point. Streamed text outruns speech by an order of magnitude, so
/// without it every shape in a lesson lands within the first two seconds while Debby is still
/// reading sentence one — which is the behaviour this replaces.
///
/// Main-thread only: `AppState` owns it and drives it from the speech delegate.
final class LessonPlayer {
    var onSay: ((String) -> Void)?
    var onDraw: ((ShapeSpec) -> Void)?
    var onPoint: ((Annotation) -> Void)?
    /// Fires and continues, like `.draw`/`.point`; execution completion does not stall
    /// narration because every action is a small, closed operation.
    var onAction: ((AppAction) -> Void)?
    /// Queue drained and no more beats coming — where auto-advance hangs off.
    var onIdle: (() -> Void)?

    private let speechEnabled: Bool
    private var queue: [Beat] = []
    private var speaking = false
    private var streamOpen = true
    private var idleFired = false
    private var cancelled = false

    /// With `voiceReplies` off nothing ever reports back, so nothing may wait.
    init(speechEnabled: Bool = true) {
        self.speechEnabled = speechEnabled
    }

    /// Beats that arrive after `cancel()` are not a reprieve: a stream the user interrupted
    /// keeps delivering for seconds afterwards, and replaying them would draw shapes and
    /// speak into the microphone that is now recording.
    func append(_ beats: [Beat]) {
        guard !cancelled else { return }
        queue += beats
        pump()
    }

    /// The model has finished; once the queue drains, the lesson is over.
    func closeStream() {
        streamOpen = false
        pump()
    }

    /// Called when the synthesiser finishes or cancels an utterance. A cancel that
    /// arrives when we are not speaking is somebody else's — ignore it rather than
    /// treating it as a completed sentence.
    func speechFinished() {
        guard speaking else { return }
        speaking = false
        pump()
    }

    func cancel() {
        cancelled = true
        queue.removeAll()
        speaking = false
        streamOpen = false
        idleFired = true
    }

    private func pump() {
        while !speaking, !queue.isEmpty {
            switch queue.removeFirst() {
            case .draw(let s):  onDraw?(s)
            case .point(let a): onPoint?(a)
            case .say(let t):
                if speechEnabled { speaking = true }
                onSay?(t)
            case .action(let a): onAction?(a)
            }
        }
        if !speaking, queue.isEmpty, !streamOpen, !idleFired {
            idleFired = true
            onIdle?()
        }
    }
}

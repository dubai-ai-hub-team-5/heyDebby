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
    /// Queue drained and no more beats coming — where auto-advance hangs off.
    var onIdle: (() -> Void)?

    private let speechEnabled: Bool
    private var queue: [Beat] = []
    private var speaking = false
    private var streamOpen = true

    /// With `voiceReplies` off nothing ever reports back, so nothing may wait.
    init(speechEnabled: Bool = true) {
        self.speechEnabled = speechEnabled
    }

    func append(_ beats: [Beat]) {
        queue += beats
        pump()
    }

    /// The model has finished; once the queue drains, the lesson is over.
    func closeStream() {
        streamOpen = false
        pump()
    }

    /// Called when the synthesiser finishes or cancels an utterance.
    func speechFinished() {
        speaking = false
        pump()
    }

    func cancel() {
        queue.removeAll()
        speaking = false
        streamOpen = false
    }

    private func pump() {
        while !speaking, !queue.isEmpty {
            switch queue.removeFirst() {
            case .draw(let s):  onDraw?(s)
            case .point(let a): onPoint?(a)
            case .say(let t):
                if speechEnabled { speaking = true }
                onSay?(t)
            }
        }
        if !speaking, queue.isEmpty, !streamOpen { onIdle?() }
    }
}

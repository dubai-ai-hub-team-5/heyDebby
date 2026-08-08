import CoreGraphics
import Foundation

actor CaptureWatchedFrameSource: WatchedFrameSource {
    private var displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func updateDisplayID(_ displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func captureFrame() async throws -> WatchedFrame? {
        let shot = try await Capture.screen(for: .interventionWatch, displayID: displayID)
        guard let fingerprint = FrameFingerprint(shot: shot) else { return nil }
        let identifier = Data(fingerprint.samples).base64EncodedString()
        return WatchedFrame(
            imageData: shot.data,
            mimeType: "image/jpeg",
            visibleContentIdentifier: identifier
        )
    }
}

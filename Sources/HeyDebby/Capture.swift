import AppKit
import ScreenCaptureKit

enum Capture {
    struct Shot {
        let base64: String
        let filePath: String
    }

    // cropTo: normalized top-left-origin rect (user's focus area), or nil for full screen.
    // displayID: the display the panel/overlays are on — capture must match it exactly.
    static func screen(excludingSelf: Bool, cropTo: CGRect? = nil,
                       displayID: CGDirectDisplayID = CGMainDisplayID()) async throws -> Shot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Can't see the screen. Grant Screen Recording in System Settings → Privacy & Security → Screen Recording, then relaunch. (\(error.localizedDescription))"])
        }
        // No arbitrary-display fallback: overlays draw on `displayID`, so capturing any
        // other screen would annotate the wrong monitor. Fail loudly instead.
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Display not found — try again"])
        }
        let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let exclude = excludingSelf ? content.windows.filter { $0.owningApplication?.processID == myPID } : []
        let filter = SCContentFilter(display: display, excludingWindows: exclude)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = true
        var cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if let c = cropTo {
            let px = CGRect(x: c.minX * CGFloat(cg.width), y: c.minY * CGFloat(cg.height),
                            width: c.width * CGFloat(cg.width), height: c.height * CGFloat(cg.height))
            if let cropped = cg.cropping(to: px) { cg = cropped }
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw NSError(domain: "capture", code: 3, userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"])
        }
        // Privacy: single overwritten temp file, never archived.
        let path = NSTemporaryDirectory() + "debby-shot.jpg"
        try jpeg.write(to: URL(fileURLWithPath: path))
        return Shot(base64: jpeg.base64EncodedString(), filePath: path)
    }
}

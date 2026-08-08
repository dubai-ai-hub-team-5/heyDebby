import AppKit
import Foundation
import ScreenCaptureKit

/// A uniquely named, permission-restricted file whose lifetime is tied to its owner.
/// Keeping this separate from `Shot` lets copies/references share one idempotent cleanup token.
fileprivate final class CaptureTemporaryFile: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var hasBeenRemoved = false

    private init(url: URL) {
        self.url = url
    }

    static func write(_ data: Data) throws -> CaptureTemporaryFile {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("HeyDebby", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)

        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory does not update an existing directory's mode.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let url = directory
            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("jpg")
        do {
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return CaptureTemporaryFile(url: url)
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasBeenRemoved else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            hasBeenRemoved = true
        } catch {
            // Leave the flag clear so an explicit cleanup or deinit can retry.
        }
    }

    deinit {
        remove()
    }
}

enum Capture {
    struct PixelDimensions: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    enum Purpose: Equatable, Sendable {
        /// A screenshot attached to a normal assistant request.
        case assistantRequest
        /// A higher-detail screenshot handed to an automation agent.
        case agentContext
        /// A small frame used only to decide whether on-screen intervention is needed.
        case interventionWatch
    }

    struct Policy: Equatable, Sendable {
        let maximumLongEdge: Int
        let jpegCompressionQuality: Double
        let showsCursor: Bool
        let excludesOwnWindows: Bool

        init(maximumLongEdge: Int, jpegCompressionQuality: Double,
             showsCursor: Bool, excludesOwnWindows: Bool) {
            precondition(maximumLongEdge > 0, "Capture long edge must be positive")
            precondition((0...1).contains(jpegCompressionQuality), "JPEG quality must be between 0 and 1")
            self.maximumLongEdge = maximumLongEdge
            self.jpegCompressionQuality = jpegCompressionQuality
            self.showsCursor = showsCursor
            self.excludesOwnWindows = excludesOwnWindows
        }
    }

    /// Reference semantics deliberately bind the temporary JPEG to the lifetime of the shot.
    /// `cleanup()` is idempotent and can be used to erase sensitive pixels before deinit.
    final class Shot: @unchecked Sendable {
        let data: Data
        let base64: String
        let filePath: String
        let width: Int
        let height: Int
        let displayID: CGDirectDisplayID

        private let temporaryFile: CaptureTemporaryFile?

        var dimensions: PixelDimensions { PixelDimensions(width: width, height: height) }
        var fileURL: URL? { filePath.isEmpty ? nil : URL(fileURLWithPath: filePath) }
        var ownsTemporaryFile: Bool { temporaryFile != nil }

        /// Preserves the initializer used by existing no-screenshot call sites. A path supplied
        /// here is considered caller-owned and is therefore never removed by this object.
        init(base64: String, filePath: String) {
            self.data = Data(base64Encoded: base64) ?? Data()
            self.base64 = base64
            self.filePath = filePath
            self.width = 0
            self.height = 0
            self.displayID = 0
            self.temporaryFile = nil
        }

        fileprivate init(data: Data, width: Int, height: Int,
                         displayID: CGDirectDisplayID,
                         temporaryFile: CaptureTemporaryFile) {
            self.data = data
            self.base64 = data.base64EncodedString()
            self.filePath = temporaryFile.url.path
            self.width = width
            self.height = height
            self.displayID = displayID
            self.temporaryFile = temporaryFile
        }

        func cleanup() {
            temporaryFile?.remove()
        }

        deinit {
            cleanup()
        }
    }

    static func policy(for purpose: Purpose) -> Policy {
        switch purpose {
        case .assistantRequest:
            return Policy(maximumLongEdge: 2_048, jpegCompressionQuality: 0.72,
                          showsCursor: true, excludesOwnWindows: true)
        case .agentContext:
            return Policy(maximumLongEdge: 2_560, jpegCompressionQuality: 0.78,
                          showsCursor: true, excludesOwnWindows: true)
        case .interventionWatch:
            return Policy(maximumLongEdge: 960, jpegCompressionQuality: 0.50,
                          showsCursor: false, excludesOwnWindows: true)
        }
    }

    // cropTo: normalized top-left-origin rect (user's focus area), or nil for full screen.
    // displayID: the display the panel/overlays are on — capture must match it exactly.
    // This signature remains source-compatible with the original AppState call sites.
    static func screen(excludingSelf: Bool, cropTo: CGRect? = nil,
                       displayID: CGDirectDisplayID = CGMainDisplayID()) async throws -> Shot {
        let standard = policy(for: .assistantRequest)
        let legacyPolicy = Policy(
            maximumLongEdge: standard.maximumLongEdge,
            jpegCompressionQuality: standard.jpegCompressionQuality,
            showsCursor: standard.showsCursor,
            excludesOwnWindows: excludingSelf
        )
        return try await screen(policy: legacyPolicy, cropTo: cropTo, displayID: displayID)
    }

    /// Preferred capture entry point. In particular, intervention frames always hide the cursor
    /// and all purpose policies exclude this process's windows.
    static func screen(for purpose: Purpose, cropTo: CGRect? = nil,
                       displayID: CGDirectDisplayID = CGMainDisplayID()) async throws -> Shot {
        try await screen(policy: policy(for: purpose), cropTo: cropTo, displayID: displayID)
    }

    /// Custom-policy seam for callers that need a different size while retaining the same safe
    /// capture pipeline. Cropping is intentionally completed before any resize operation.
    static func screen(policy: Policy, cropTo: CGRect? = nil,
                       displayID: CGDirectDisplayID = CGMainDisplayID()) async throws -> Shot {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Can't see the screen. Grant Screen Recording in System Settings → Privacy & Security → Screen Recording, then relaunch. (\(error.localizedDescription))"])
        }

        // No arbitrary-display fallback: overlays draw on `displayID`, so capturing any
        // other screen would annotate the wrong monitor. Fail loudly instead.
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "capture", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Display not found — try again"])
        }

        let filter = contentFilter(
            content: content,
            display: display,
            excludesOwnWindows: policy.excludesOwnWindows
        )
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = policy.showsCursor
        configuration.capturesAudio = false

        var image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        image = try cropped(image, to: cropTo)
        image = try downscaled(image, maximumLongEdge: policy.maximumLongEdge)

        let representation = NSBitmapImageRep(cgImage: image)
        guard let jpeg = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: policy.jpegCompressionQuality]
        ) else {
            throw NSError(domain: "capture", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "JPEG encode failed"])
        }

        let temporaryFile = try CaptureTemporaryFile.write(jpeg)
        return Shot(
            data: jpeg,
            width: image.width,
            height: image.height,
            displayID: displayID,
            temporaryFile: temporaryFile
        )
    }

    /// Pure sizing helper used by the renderer and suitable for boundary tests.
    static func downscaledDimensions(width: Int, height: Int,
                                     maximumLongEdge: Int) -> PixelDimensions {
        guard width > 0, height > 0, maximumLongEdge > 0 else {
            return PixelDimensions(width: 0, height: 0)
        }
        let longEdge = max(width, height)
        guard longEdge > maximumLongEdge else {
            return PixelDimensions(width: width, height: height)
        }
        let scale = Double(maximumLongEdge) / Double(longEdge)
        return PixelDimensions(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    private static func contentFilter(content: SCShareableContent, display: SCDisplay,
                                      excludesOwnWindows: Bool) -> SCContentFilter {
        guard excludesOwnWindows else {
            return SCContentFilter(display: display, excludingWindows: [])
        }

        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        if let ownApplication = content.applications.first(where: { $0.processID == processID }) {
            // Excluding the running application is stronger than snapshotting its current window
            // list: a panel created between enumeration and capture is excluded as well.
            return SCContentFilter(
                display: display,
                excludingApplications: [ownApplication],
                exceptingWindows: []
            )
        }

        // The application can be absent from `applications` very early during launch. Exclude
        // every window currently attributed to our PID as a conservative fallback.
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == processID
        }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    private static func cropped(_ image: CGImage, to normalizedRect: CGRect?) throws -> CGImage {
        guard let normalizedRect else { return image }
        let values = [normalizedRect.minX, normalizedRect.minY,
                      normalizedRect.maxX, normalizedRect.maxY]
        guard values.allSatisfy({ $0.isFinite }) else {
            throw NSError(domain: "capture", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Capture crop is invalid"])
        }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = normalizedRect.standardized.intersection(unitRect)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw NSError(domain: "capture", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Capture crop is outside the display"])
        }

        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let minX = floor(clipped.minX * imageWidth)
        let minY = floor(clipped.minY * imageHeight)
        let maxX = ceil(clipped.maxX * imageWidth)
        let maxY = ceil(clipped.maxY * imageHeight)
        let pixelRect = CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        guard let cropped = image.cropping(to: pixelRect) else {
            throw NSError(domain: "capture", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Capture crop failed"])
        }
        return cropped
    }

    private static func downscaled(_ image: CGImage, maximumLongEdge: Int) throws -> CGImage {
        let target = downscaledDimensions(
            width: image.width,
            height: image.height,
            maximumLongEdge: maximumLongEdge
        )
        guard target.width != image.width || target.height != image.height else { return image }
        guard target.width > 0, target.height > 0 else {
            throw NSError(domain: "capture", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Capture resize dimensions are invalid"])
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "capture", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Capture resize failed"])
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(target.width),
            height: CGFloat(target.height)
        ))
        guard let resized = context.makeImage() else {
            throw NSError(domain: "capture", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Capture resize failed"])
        }
        return resized
    }
}

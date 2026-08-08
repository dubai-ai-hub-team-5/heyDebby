import AppKit
import CoreGraphics
import Foundation

/// A deterministic, deliberately small luminance representation of a screen frame.
/// The fixed-size byte vector is cheap to retain and compare, while preserving more signal
/// than a single digest (cryptographic hashes make even JPEG noise look like a total change).
struct FrameFingerprint: Equatable, Sendable {
    static let defaultWidth = 16
    static let defaultHeight = 16

    let width: Int
    let height: Int
    let samples: [UInt8]

    var sampleCount: Int { samples.count }

    /// Pure construction seam for unit tests and callers that already have luminance samples.
    init(samples: [UInt8], width: Int = defaultWidth, height: Int = defaultHeight) {
        precondition(width > 0 && height > 0, "Fingerprint dimensions must be positive")
        precondition(samples.count == width * height,
                     "Fingerprint sample count must match its dimensions")
        self.width = width
        self.height = height
        self.samples = samples
    }

    /// Converts an image into sRGB RGBA at the target size, then applies an integer luminance
    /// transform. Integer coefficients keep output stable across runs and avoid platform SIMD
    /// or floating-point rounding differences in the fingerprint itself.
    init?(image: CGImage, width: Int = defaultWidth, height: Int = defaultHeight) {
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(baseAddress),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }

            // Screenshots are opaque, but a fixed black backing also makes transparent test
            // fixtures deterministic rather than depending on uninitialized destination bytes.
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            ))
            return true
        }
        guard rendered else { return nil }

        var luminance = [UInt8]()
        luminance.reserveCapacity(width * height)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            // Integer approximation of Rec. 709: 0.2126 R + 0.7152 G + 0.0722 B.
            luminance.append(UInt8((54 * red + 183 * green + 19 * blue + 128) >> 8))
        }

        self.init(samples: luminance, width: width, height: height)
    }

    init?(imageData: Data, width: Int = defaultWidth, height: Int = defaultHeight) {
        guard let representation = NSBitmapImageRep(data: imageData),
              let image = representation.cgImage else { return nil }
        self.init(image: image, width: width, height: height)
    }

    init?(shot: Capture.Shot, width: Int = defaultWidth, height: Int = defaultHeight) {
        self.init(imageData: shot.data, width: width, height: height)
    }

    /// Normalized mean absolute luminance distance in 0...1. Fingerprints with incompatible
    /// dimensions return 1 (maximum distance), avoiding a false "unchanged" decision.
    func distance(to other: FrameFingerprint) -> Double {
        Self.distance(between: self, and: other)
    }

    /// Static form makes the metric directly testable without detector state or wall-clock input.
    static func distance(between lhs: FrameFingerprint,
                         and rhs: FrameFingerprint) -> Double {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.samples.count == rhs.samples.count,
              !lhs.samples.isEmpty else { return 1 }

        var totalDifference: UInt64 = 0
        for index in lhs.samples.indices {
            totalDifference += UInt64(abs(Int(lhs.samples[index]) - Int(rhs.samples[index])))
        }
        let maximumDifference = UInt64(lhs.samples.count) * UInt64(UInt8.max)
        return Double(totalDifference) / Double(maximumDifference)
    }
}

enum FrameChangeDecision: Equatable, Sendable {
    /// The first valid frame establishes a baseline and should not trigger an intervention.
    case firstFrame
    case unchanged(distance: Double)
    case changed(distance: Double)

    var didChange: Bool {
        if case .changed = self { return true }
        return false
    }

    /// A baseline still merits one evaluation; only a proven unchanged frame can be skipped.
    var shouldEvaluate: Bool {
        if case .unchanged = self { return false }
        return true
    }

    var distance: Double? {
        switch self {
        case .firstFrame:
            return nil
        case .unchanged(let distance), .changed(let distance):
            return distance
        }
    }
}

/// Stateless threshold policy for deciding if two visual fingerprints differ enough to act on.
/// All decision methods are pure, so boundary behavior can be tested with explicit byte fixtures.
struct FrameChangePolicy: Equatable, Sendable {
    static let interventionWatch = FrameChangePolicy(distanceThreshold: 0.025)

    let distanceThreshold: Double

    init(distanceThreshold: Double) {
        precondition(distanceThreshold.isFinite && (0...1).contains(distanceThreshold),
                     "Frame-change threshold must be finite and between 0 and 1")
        self.distanceThreshold = distanceThreshold
    }

    func decision(previous: FrameFingerprint?, current: FrameFingerprint) -> FrameChangeDecision {
        guard let previous else { return .firstFrame }
        return decision(distance: previous.distance(to: current))
    }

    func decision(distance: Double) -> FrameChangeDecision {
        Self.decision(distance: distance, threshold: distanceThreshold)
    }

    /// Threshold equality is considered changed; callers can therefore state the exact minimum
    /// distance that should trigger work. Invalid distances are conservatively treated as changed.
    static func decision(distance: Double, threshold: Double) -> FrameChangeDecision {
        guard distance.isFinite, threshold.isFinite,
              (0...1).contains(distance), (0...1).contains(threshold) else {
            return .changed(distance: 1)
        }
        if distance >= threshold {
            return .changed(distance: distance)
        }
        return .unchanged(distance: distance)
    }
}

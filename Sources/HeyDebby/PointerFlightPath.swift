import CoreGraphics
import Foundation

struct PointerFlightPath: Equatable {
    let start: CGPoint
    let end: CGPoint
    let control: CGPoint
    let duration: TimeInterval

    init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
        let distance = hypot(end.x - start.x, end.y - start.y)
        self.duration = min(max(distance / 800, 0.45), 1.2)
        self.control = CGPoint(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2 + min(distance * 0.2, 80)
        )
    }

    func point(at progress: Double) -> CGPoint {
        let linear = min(max(progress, 0), 1)
        let t = linear * linear * (3 - 2 * linear)
        let inverse = 1 - t
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
            y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
        )
    }

    func rotation(at progress: Double) -> Double {
        let linear = min(max(progress, 0), 1)
        let t = linear * linear * (3 - 2 * linear)
        let inverse = 1 - t
        let dx = 2 * inverse * (control.x - start.x) + 2 * t * (end.x - control.x)
        let dy = 2 * inverse * (control.y - start.y) + 2 * t * (end.y - control.y)
        return atan2(-dy, dx) * 180 / .pi + 90
    }

    func scale(at progress: Double) -> CGFloat {
        1 + sin(min(max(progress, 0), 1) * .pi) * 0.25
    }
}

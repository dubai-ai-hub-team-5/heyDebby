import Foundation

struct InterventionTiming: Equatable, Sendable {
    let captureMilliseconds: Int
    let evidenceMilliseconds: Int
    let modelMilliseconds: Int
    let totalMilliseconds: Int
    let producedIntervention: Bool

    var logLine: String {
        "INTERVENTION timing capture=\(captureMilliseconds)ms evidence=\(evidenceMilliseconds)ms model=\(modelMilliseconds)ms total=\(totalMilliseconds)ms result=\(producedIntervention ? "intervene" : "silent")"
    }
}

import Foundation

enum InterventionPresentationState: Equatable {
    case idle
    case watching
    case evaluating
    case presenting
    case sourceOpened
    case executing
    case completed(String)
    case failed(String)
    case muted
}

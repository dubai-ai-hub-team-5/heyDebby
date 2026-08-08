import AppKit
import CoreGraphics
import Foundation

struct TalkChordTransitionState: Equatable {
    var isTalkDown = false
    var talkPressedAt: TimeInterval?
    var isKillKeyDown = false
}

enum TalkChordInput: Equatable {
    case flagsChanged(NSEvent.ModifierFlags)
    case keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool)
    case keyUp(keyCode: UInt16, flags: NSEvent.ModifierFlags)

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .flagsChanged(let flags), .keyDown(_, let flags, _), .keyUp(_, let flags): return flags
        }
    }
}

enum TalkChordEffect: Equatable {
    case talkChanged(down: Bool, heldFor: TimeInterval)
    case proactiveKill
}

private let proactiveKillKeyCode: UInt16 = 40

/// ⌃⌥ with no ⌘/⇧ is talk; Caps Lock and Fn do not make the chord stop working.
func talkChordIsPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    return flags.contains(.control) && flags.contains(.option)
        && !flags.contains(.command) && !flags.contains(.shift)
}

func proactiveKillChordIsPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    return flags.contains(.command) && flags.contains(.shift)
        && !flags.contains(.control) && !flags.contains(.option)
}

/// Pure reducer for modifier ordering, key repeat, and hold-duration tests.
func transitionTalkChord(_ state: TalkChordTransitionState, input: TalkChordInput,
                         at time: TimeInterval) -> (state: TalkChordTransitionState,
                                                    effects: [TalkChordEffect]) {
    var next = state
    var effects: [TalkChordEffect] = []
    let talkDown = talkChordIsPressed(input.flags)
    if talkDown != next.isTalkDown {
        next.isTalkDown = talkDown
        if talkDown {
            next.talkPressedAt = time
            effects.append(.talkChanged(down: true, heldFor: 0))
        } else {
            let held = max(0, time - (next.talkPressedAt ?? time))
            next.talkPressedAt = nil
            effects.append(.talkChanged(down: false, heldFor: held))
        }
    }

    if !proactiveKillChordIsPressed(input.flags) { next.isKillKeyDown = false }
    switch input {
    case .keyDown(let keyCode, let flags, let isRepeat):
        guard keyCode == proactiveKillKeyCode,
              proactiveKillChordIsPressed(flags), !isRepeat, !next.isKillKeyDown else { break }
        next.isKillKeyDown = true
        effects.append(.proactiveKill)
    case .keyUp(let keyCode, _):
        if keyCode == proactiveKillKeyCode { next.isKillKeyDown = false }
    case .flagsChanged:
        break
    }
    return (next, effects)
}

private final class TalkChordResources {
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var globalMonitor: Any?
    var localMonitor: Any?

    func clear() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        eventTap = nil
        runLoopSource = nil
        globalMonitor = nil
        localMonitor = nil
    }

    deinit { clear() }
}

private func flags(from event: CGEvent) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
}

private func input(type: CGEventType, event: CGEvent) -> TalkChordInput? {
    let flags = flags(from: event)
    switch type {
    case .flagsChanged:
        return .flagsChanged(flags)
    case .keyDown:
        return .keyDown(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    case .keyUp:
        return .keyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: flags)
    default:
        return nil
    }
}

private func input(from event: NSEvent) -> TalkChordInput? {
    switch event.type {
    case .flagsChanged:
        return .flagsChanged(event.modifierFlags)
    case .keyDown:
        return .keyDown(keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat)
    case .keyUp:
        return .keyUp(keyCode: event.keyCode, flags: event.modifierFlags)
    default:
        return nil
    }
}

private func enqueue(_ monitor: TalkChordMonitor, _ input: TalkChordInput,
                     at time: TimeInterval) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { monitor.receive(input, at: time) }
    }
}

private func talkChordEventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                      _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<TalkChordMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { monitor.reenableAfterTapDisable() }
        }
    } else if let input = input(type: type, event: event) {
        enqueue(monitor, input, at: ProcessInfo.processInfo.systemUptime)
    }
    return Unmanaged.passUnretained(event)
}

/// Lifecycle owner for the listen-only global talk/kill keyboard observation.
@MainActor
final class TalkChordMonitor {
    enum Backend: Equatable { case eventTap, eventMonitors }
    typealias TalkHandler = @MainActor (_ down: Bool, _ heldFor: TimeInterval) -> Void
    typealias KillHandler = @MainActor () -> Void

    /// Hardware key code for ANSI K; modifier matching remains layout-independent.
    static let proactiveKillKeyCode: UInt16 = 40

    var onTalkChord: TalkHandler?
    var onProactiveKill: KillHandler?
    private(set) var backend: Backend?
    var isRunning: Bool { backend != nil }

    private let resources = TalkChordResources()
    private var transitionState = TalkChordTransitionState()

    init(onTalkChord: TalkHandler? = nil, onProactiveKill: KillHandler? = nil) {
        self.onTalkChord = onTalkChord
        self.onProactiveKill = onProactiveKill
    }

    /// Idempotent. Returns true when either the event tap or retained NSEvent fallback is active.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        resources.clear()
        transitionState = TalkChordTransitionState()

        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
            | CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.keyUp.rawValue
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: talkChordEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            resources.eventTap = tap
            resources.runLoopSource = source
            backend = .eventTap
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        resources.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) {
            [weak self] event in
            guard let self, let input = input(from: event) else { return }
            enqueue(self, input, at: ProcessInfo.processInfo.systemUptime)
        }
        resources.localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) {
            [weak self] event in
            if let self, let input = input(from: event) {
                enqueue(self, input, at: ProcessInfo.processInfo.systemUptime)
            }
            return event
        }
        if resources.globalMonitor != nil || resources.localMonitor != nil {
            backend = .eventMonitors
        }
        return isRunning
    }

    /// Idempotent and silent: stopping observation does not synthesize a talk release.
    func stop() {
        guard isRunning || resources.eventTap != nil || resources.globalMonitor != nil
                || resources.localMonitor != nil else { return }
        backend = nil
        resources.clear()
        transitionState = TalkChordTransitionState()
    }

    fileprivate func receive(_ input: TalkChordInput, at time: TimeInterval) {
        guard isRunning else { return }
        let result = transitionTalkChord(transitionState, input: input, at: time)
        transitionState = result.state
        for effect in result.effects {
            switch effect {
            case .talkChanged(let down, let heldFor): onTalkChord?(down, heldFor)
            case .proactiveKill: onProactiveKill?()
            }
        }
    }

    fileprivate func reenableAfterTapDisable() {
        guard backend == .eventTap, let tap = resources.eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        let flags = CGEventSource.flagsState(.combinedSessionState)
        receive(.flagsChanged(NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))),
                at: ProcessInfo.processInfo.systemUptime)
    }
}

import AppKit

/// ⌃⌥ held together with no ⌘/⇧ — Debby's talk chord.
func isTalkChord(_ flags: NSEvent.ModifierFlags) -> Bool {
    let m = flags.intersection(.deviceIndependentFlagsMask)
    return m.contains(.control) && m.contains(.option) && !m.contains(.command) && !m.contains(.shift)
}

/// Hold ⌃⌥ to talk, quick-tap to latch. Modifier-only chords can't be Carbon hot keys,
/// so we watch flagsChanged — which needs Accessibility permission (prompted at launch).
enum Hotkey {
    private static var down = false
    private static var pressedAt = Date()

    static func watchTalkChord(_ change: @escaping (_ down: Bool, _ heldFor: TimeInterval) -> Void) {
        let handle: (NSEvent) -> Void = { e in
            let held = isTalkChord(e.modifierFlags)
            guard held != down else { return }
            down = held
            let elapsed = held ? 0 : Date().timeIntervalSince(pressedAt)
            if held { pressedAt = Date() }
            DispatchQueue.main.async { change(held, elapsed) }
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        _ = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { handle($0); return $0 }
    }
}

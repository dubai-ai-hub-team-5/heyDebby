import AppKit
import SwiftUI

enum RailMetrics {
    /// The pill. Wide enough for a few words of the newest output line, narrow enough
    /// that a permanently-live strip down the side of the screen isn't in the way.
    static let collapsed: CGFloat = 216
    /// The hovered card, which has room for the output tail and its buttons.
    static let expanded: CGFloat = 380
    static let gap: CGFloat = 8
    static let margin: CGFloat = 14
    /// Tail lines shown on the hovered card. More than this and the card starts competing
    /// with the window it is floating over; the log has the rest, verbatim.
    static let tailLines = 8
}

/// The strip of screen the rail catches the mouse in.
///
/// The window itself is always the full expanded width, because a card has to be able to
/// grow leftward without the window clipping it. If that whole width swallowed clicks,
/// the rail would black-hole a 380pt column of whatever app is underneath — so the window
/// stays click-through except inside this rect, which is only as wide as the cards
/// actually drawn: the pills normally, the expanded card while one is hovered.
///
/// Widening it on hover is what keeps the expansion stable. Without it, moving the cursor
/// left onto the part of the card that just appeared would leave the hit region, turn
/// `ignoresMouseEvents` back on, collapse the card out from under the cursor, and start
/// again — a flicker loop rather than a hover.
func railHitRect(visible: CGRect, expanded: Bool) -> CGRect {
    let w = (expanded ? RailMetrics.expanded : RailMetrics.collapsed) + RailMetrics.margin * 2
    return CGRect(x: visible.maxX - w, y: visible.minY, width: w, height: visible.height)
}

/// Full-height panel down the right edge. Ordered out entirely when no agents are
/// running, so an idle Mac has nothing floating on it.
@MainActor
final class AgentRailWindow: NSPanel {
    init(state: AppState) {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Below the notch's .statusBar but above ordinary windows: the rail must not
        // cover the menu bar, and nothing it shows is worth hiding the notch for.
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true   // AppState.trackMouse flips this over the cards
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: AgentRailView().environmentObject(state))
        reposition()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// Never key: taking key focus would deactivate whatever the user is working in, and
    /// the rail has no text to type into — Confirm and Stop are clicks.
    override var canBecomeKey: Bool { false }

    func reposition() {
        let v = NSScreen.notchHost.visibleFrame
        let w = RailMetrics.expanded + RailMetrics.margin * 2
        setFrame(NSRect(x: v.maxX - w, y: v.minY, width: w, height: v.height), display: false)
    }
}

struct AgentRailView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .trailing, spacing: RailMetrics.gap) {
            ForEach(state.agents) { run in
                AgentCard(run: run, expanded: state.railHover == run.id)
                    .onHover { inside in
                        // Latch on enter, and only clear if this card is still the one
                        // showing: cards reflow as runs finish, so a stale exit event
                        // from a card the cursor already left must not close its
                        // replacement.
                        if inside { state.railHover = run.id }
                        else if state.railHover == run.id { state.railHover = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, RailMetrics.margin)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.railHover)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.agents.map(\.id))
    }
}

struct AgentCard: View {
    @ObservedObject var run: AgentRun
    let expanded: Bool
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            header
            if expanded {
                if !run.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(run.lines.suffix(RailMetrics.tailLines).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                buttons
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: expanded ? RailMetrics.expanded : RailMetrics.collapsed, alignment: .leading)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(spacing: 7) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                // Both show the task; expanded just has room for two lines of it and the
                // output underneath. See `AgentRun.summary` for why the pill is not a
                // progress line.
                Text(expanded ? run.task : run.summary)
                    .font(.system(size: 11, weight: expanded ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(expanded ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: expanded)
                if expanded, case .asking(let q) = run.status {
                    Text(q).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch run.status {
        case .running:      ProgressView().controlSize(.mini).tint(.white)
        case .asking:       Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .done:         Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:       Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .stopped:      Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
        // .font on the ProgressView branch would be ignored; applying it here keeps the
        // three symbol cases the same size as each other.
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if case .asking = run.status {
                Button("Confirm") { state.confirm(run) }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.orange)
                Button("Cancel") { state.cancel(run) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if run.isFinished {
                meta(finishedLabel)
                Spacer(minLength: 0)
                Button("Dismiss") { state.dismiss(run) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                meta(elapsed)
                Spacer(minLength: 0)
                Button("Stop") { state.stop(run) }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)
            }
        }
        .frame(minHeight: 20)
    }

    /// `.secondary` is a light-mode-ish grey that all but vanishes on this card's near
    /// black, and it was clipping against the button row's baseline.
    private func meta(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize()
    }

    private var finishedLabel: String {
        switch run.status {
        case .done:            return "done"
        case .failed(let c):   return "exited \(c)"
        case .stopped:         return "stopped"
        default:               return ""
        }
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(run.startedAt))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private var tint: Color {
        switch run.status {
        case .running:  return .white
        case .asking:   return .orange
        case .done:     return .green
        case .failed:   return .red
        case .stopped:  return .secondary
        }
    }
}

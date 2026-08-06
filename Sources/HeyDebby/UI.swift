import AppKit
import AVFoundation
import SwiftUI

// MARK: - Drawing tools + shapes

enum DrawTool: String, CaseIterable, Equatable {
    case pen, line, arrow, curve, rectangle, circle, triangle, polygon, square, text

    /// The toolbar's tools. `text` needs a label and `polygon` needs N clicks — both are
    /// AI-only; a single drag can't express either. `square` is a drag, but of a side, not a box.
    static var manual: [DrawTool] { allCases.filter { $0 != .text && $0 != .polygon } }

    var icon: String {
        switch self {
        case .pen:       return "pencil"
        case .line:      return "line.diagonal"
        case .arrow:     return "arrow.up.right"
        case .curve:     return "scribble"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .triangle:  return "triangle"
        case .polygon:   return "pentagon"
        case .square:    return "square"
        case .text:      return "textformat"
        }
    }
}

struct DrawnShape: Identifiable {
    let id = UUID()
    let tool: DrawTool
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var label: String = ""   // .text only

    func buildPath() -> Path {
        if tool == .text { return Path() }   // drawn as text, not stroked
        guard points.count >= 2 else { return Path() }
        let start = points[0], end = points[points.count - 1]
        switch tool {
        case .pen:
            var p = Path(); p.move(to: points[0])
            for pt in points.dropFirst() { p.addLine(to: pt) }
            return p
        case .curve:
            return catmullRom(points)
        case .line:
            var p = Path(); p.move(to: start); p.addLine(to: end); return p
        case .arrow:
            return arrowPath(from: start, to: end, lw: lineWidth)
        case .rectangle:
            var p = Path()
            p.addRect(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y)))
            return p
        case .circle:
            let dx = end.x - start.x, dy = end.y - start.y
            let r = (dx*dx + dy*dy).squareRoot()
            var p = Path()
            p.addEllipse(in: CGRect(x: start.x - r, y: start.y - r, width: r*2, height: r*2))
            return p
        case .triangle:
            var p = Path()
            // 3 points = the actual vertices the AI asked for. A right triangle can't be
            // expressed as a bounding box, and that box is all a hand-drag can give — so the
            // 2-point isosceles fallback stays for the toolbar only.
            if points.count >= 3 {
                p.move(to: points[0])
                for pt in points.dropFirst().prefix(2) { p.addLine(to: pt) }
            } else {
                let top = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y))
                let bl  = CGPoint(x: min(start.x, end.x),   y: max(start.y, end.y))
                let br  = CGPoint(x: max(start.x, end.x),   y: max(start.y, end.y))
                p.move(to: top); p.addLine(to: bl); p.addLine(to: br)
            }
            p.closeSubpath()
            return p
        case .square:
            // A square standing ON the side start→end. Computed here, in screen points, because
            // this is where a perpendicular is just (-dy, dx) — in normalized coordinates it
            // needs the aspect ratio, and the model gets that arithmetic wrong every time.
            // Swapping start and end flips the square to the other side of the line.
            let perp = CGPoint(x: -(end.y - start.y), y: end.x - start.x)
            var p = Path()
            p.move(to: start)
            p.addLine(to: end)
            p.addLine(to: CGPoint(x: end.x + perp.x, y: end.y + perp.y))
            p.addLine(to: CGPoint(x: start.x + perp.x, y: start.y + perp.y))
            p.closeSubpath()
            return p
        case .polygon:
            // The only way to draw an arbitrary rotated shape — rectangle is axis-aligned by
            // construction.
            var p = Path()
            p.move(to: points[0])
            for pt in points.dropFirst() { p.addLine(to: pt) }
            p.closeSubpath()
            return p
        case .text:
            return Path()
        }
    }

    private func arrowPath(from s: CGPoint, to e: CGPoint, lw: CGFloat) -> Path {
        var p = Path(); p.move(to: s); p.addLine(to: e)
        let angle = atan2(e.y - s.y, e.x - s.x)
        let head: CGFloat = max(14, lw * 4)
        let spread: CGFloat = 0.42
        p.move(to: e)
        p.addLine(to: CGPoint(x: e.x - head * cos(angle - spread), y: e.y - head * sin(angle - spread)))
        p.move(to: e)
        p.addLine(to: CGPoint(x: e.x - head * cos(angle + spread), y: e.y - head * sin(angle + spread)))
        return p
    }

    private func catmullRom(_ pts: [CGPoint]) -> Path {
        guard pts.count >= 2 else { return Path() }
        var p = Path(); p.move(to: pts[0])
        for i in 1..<pts.count {
            let p0 = pts[max(0, i - 2)], p1 = pts[i - 1]
            let p2 = pts[i], p3 = pts[min(pts.count - 1, i + 1)]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            p.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return p
    }
}

// MARK: - Drawing controller

@MainActor
final class DrawingController: ObservableObject {
    static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .white]

    @Published var isActive = false
    @Published var tool: DrawTool = .arrow
    @Published var shapes: [DrawnShape] = []
    @Published var colorIndex: Int = 0
    @Published var lineWidth: CGFloat = 3
    @Published var currentShape: DrawnShape?

    var onStop: (() -> Void)?
    var drawColor: Color { Self.palette[min(colorIndex, Self.palette.count - 1)] }

    private var canvasWindow: NSWindow?
    private var toolbarWindow: NSWindow?
    private var pushedCursor = false

    /// `interactive: false` is how the AI draws: the canvas passes clicks straight through and
    /// there is no toolbar or crosshair, so illustrating something doesn't shove the user into
    /// drawing mode and block the screen they're trying to read.
    func start(on screen: NSScreen, interactive: Bool = true) {
        guard !isActive else { return }
        isActive = true
        shapes.removeAll()
        currentShape = nil

        let canvas = NSPanel(contentRect: screen.frame,
                             styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        canvas.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.hasShadow = false
        canvas.ignoresMouseEvents = !interactive
        canvas.isFloatingPanel = true
        canvas.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        canvas.contentView = NSHostingView(rootView: DrawingCanvasView(controller: self,
                                                                       size: screen.frame.size,
                                                                       interactive: interactive))
        canvas.orderFrontRegardless()
        canvasWindow = canvas
        guard interactive else { return }
        NSCursor.crosshair.push()
        pushedCursor = true

        let tbW: CGFloat = 460, tbH: CGFloat = 54
        let tbRect = CGRect(x: screen.frame.midX - tbW / 2,
                            y: screen.frame.minY + 24,
                            width: tbW, height: tbH)
        let toolbar = NSPanel(contentRect: tbRect,
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        toolbar.backgroundColor = .clear
        toolbar.isOpaque = false
        toolbar.hasShadow = true
        toolbar.ignoresMouseEvents = false
        toolbar.isFloatingPanel = true
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbar.contentView = NSHostingView(rootView: DrawingToolbarView(controller: self))
        toolbar.orderFrontRegardless()
        toolbarWindow = toolbar
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        currentShape = nil
        canvasWindow?.orderOut(nil); canvasWindow = nil
        toolbarWindow?.orderOut(nil); toolbarWindow = nil
        if pushedCursor { NSCursor.pop(); pushedCursor = false }  // unbalanced pop breaks the cursor
        onStop?()
    }

    func clearShapes() { shapes.removeAll(); currentShape = nil }
}

// MARK: - Drawing canvas view

struct DrawingCanvasView: View {
    @ObservedObject var controller: DrawingController
    let size: CGSize
    var interactive = true

    var body: some View {
        ZStack {
            Color.clear
            Canvas { ctx, _ in
                let all = controller.shapes + (controller.currentShape.map { [$0] } ?? [])
                for shape in all {
                    if shape.tool == .text {
                        guard let at = shape.points.first, !shape.label.isEmpty else { continue }
                        // Shadowed so labels stay readable over whatever is on screen.
                        let t = Text(shape.label)
                            .font(.system(size: max(22, shape.lineWidth * 7), weight: .bold))
                        ctx.draw(t.foregroundColor(.black.opacity(0.55)),
                                 at: CGPoint(x: at.x + 1, y: at.y + 1), anchor: .center)
                        ctx.draw(t.foregroundColor(shape.color), at: at, anchor: .center)
                    } else {
                        ctx.stroke(shape.buildPath(), with: .color(shape.color),
                                   style: StrokeStyle(lineWidth: shape.lineWidth,
                                                      lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(interactive)
        .contentShape(Rectangle())
        .onHover { _ in if interactive { NSCursor.crosshair.set() } }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    let loc = v.location
                    switch controller.tool {
                    case .pen, .curve:
                        if controller.currentShape == nil {
                            controller.currentShape = DrawnShape(tool: controller.tool,
                                                                  points: [v.startLocation],
                                                                  color: controller.drawColor,
                                                                  lineWidth: controller.lineWidth)
                        }
                        if let last = controller.currentShape?.points.last {
                            let dx = loc.x - last.x, dy = loc.y - last.y
                            if dx*dx + dy*dy > 9 { controller.currentShape?.points.append(loc) }
                        }
                    default:
                        controller.currentShape = DrawnShape(tool: controller.tool,
                                                              points: [v.startLocation, loc],
                                                              color: controller.drawColor,
                                                              lineWidth: controller.lineWidth)
                    }
                }
                .onEnded { v in
                    if let shape = controller.currentShape {
                        let pts = shape.points
                        let moved: Bool
                        if pts.count < 2 {
                            moved = shape.tool == .pen || shape.tool == .curve
                        } else {
                            let dx = pts.last!.x - pts[0].x, dy = pts.last!.y - pts[0].y
                            moved = dx*dx + dy*dy > 25
                        }
                        if moved { controller.shapes.append(shape) }
                    }
                    controller.currentShape = nil
                }
        )
    }
}

// MARK: - Drawing toolbar

struct DrawingToolbarView: View {
    @ObservedObject var controller: DrawingController
    private let widths: [CGFloat] = [2, 4, 7]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(DrawTool.manual, id: \.self) { tool in
                Button { controller.tool = tool } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(controller.tool == tool ? Color.orange : Color.white.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(controller.tool == tool ? .black : .white)
                }
                .buttonStyle(.plain)
            }

            divider

            ForEach(DrawingController.palette.indices, id: \.self) { i in
                Button { controller.colorIndex = i } label: {
                    Circle()
                        .fill(DrawingController.palette[i])
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white.opacity(0.9),
                                                       lineWidth: controller.colorIndex == i ? 2.5 : 0))
                }
                .buttonStyle(.plain)
            }

            divider

            ForEach(widths, id: \.self) { w in
                Button { controller.lineWidth = w } label: {
                    Circle()
                        .fill(Color.white.opacity(controller.lineWidth == w ? 1.0 : 0.4))
                        .frame(width: w * 2.5 + 3, height: w * 2.5 + 3)
                }
                .buttonStyle(.plain)
                .frame(width: 24)
            }

            divider

            Button("Clear") { controller.clearShapes() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Button("Done") { controller.stop() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.orange, in: Capsule())
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.black.opacity(0.88), in: Capsule())
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 22)
    }
}

extension NSScreen {
    static var underMouse: NSScreen {
        let m = NSEvent.mouseLocation
        return screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? main ?? screens.first!
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The display that owns the menu bar (and the notch) — the HUD lives there.
    /// ponytail: one HUD on the primary display; mirror it per-screen only if asked.
    static var notchHost: NSScreen { screens.first ?? main ?? screens[0] }

    /// The physical notch, or a slim pill on displays that don't have one.
    var collapsedNotch: CGSize {
        guard safeAreaInsets.top > 0, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else {
            return NotchMetrics.fallbackCollapsed
        }
        let w = frame.width - l.width - r.width
        return w > 40 ? CGSize(width: w, height: safeAreaInsets.top) : NotchMetrics.fallbackCollapsed
    }
}

enum NotchMetrics {
    static let expanded = CGSize(width: 460, height: 144)
    static let fallbackCollapsed = CGSize(width: 168, height: 26)
    /// Canvas the HUD is drawn in — big enough for the open state, top-centered.
    static let window = CGSize(width: 520, height: 200)
}

/// Screen-coordinate rect of the visible HUD surface (top-centered, hugging the screen edge).
func notchRect(screen: CGRect, collapsed: CGSize, expanded isOpen: Bool) -> CGRect {
    let s = isOpen ? NotchMetrics.expanded : collapsed
    return CGRect(x: screen.midX - s.width / 2, y: screen.maxY - s.height, width: s.width, height: s.height)
}

// MARK: - Notch HUD (every control lives here; click-through until you touch it)

final class NotchWindow: NSPanel {
    init(state: AppState) {
        super.init(contentRect: NSRect(origin: .zero, size: NotchMetrics.window),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar          // above the menu bar, so it can own the notch
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true   // AppState.trackMouse flips this when you hover
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: NotchView()
            .environmentObject(state)
            .environmentObject(state.drawingController))
        reposition()
        orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    override var canBecomeKey: Bool { true }

    func reposition() {
        let f = NSScreen.notchHost.frame
        setFrameOrigin(NSPoint(x: f.midX - NotchMetrics.window.width / 2,
                               y: f.maxY - NotchMetrics.window.height))
    }
}

struct NotchView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var drawing: DrawingController

    private var notch: CGSize { NSScreen.notchHost.collapsedNotch }
    private var open: Bool { state.notchExpanded }

    var body: some View {
        VStack(spacing: 0) {
            shell
            Spacer(minLength: 0)
        }
        .frame(width: NotchMetrics.window.width, height: NotchMetrics.window.height)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: open)
    }

    private var shell: some View {
        VStack(spacing: 0) {
            topRow
            if open {
                openContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: open ? NotchMetrics.expanded.width : notch.width,
               height: open ? NotchMetrics.expanded.height : notch.height, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: open ? 22 : 8,
                                          bottomTrailingRadius: open ? 22 : 8))
        .overlay(
            UnevenRoundedRectangle(bottomLeadingRadius: open ? 22 : 8, bottomTrailingRadius: open ? 22 : 8)
                .strokeBorder(Color.white.opacity(open ? 0.12 : 0), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 18, y: 8)
    }

    /// Flanks the physical notch: nothing is drawn behind the camera housing.
    private var topRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if state.isListening {
                    Image(systemName: "mic.fill").foregroundStyle(.orange)
                } else if state.container != nil {
                    Image(systemName: "viewfinder").foregroundStyle(.orange)
                }
            }
            .padding(.trailing, 10)
            Color.clear.frame(width: notch.width)
            HStack(spacing: 6) {
                if state.isThinking || state.agentBusy {
                    ProgressView().controlSize(.mini).tint(.white)
                } else if state.isListening {
                    Waveform(levels: state.levels.suffix(10).map { $0 }, height: 12, barWidth: 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(height: max(notch.height, 22))
    }

    private var openContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: state.toggleListening) {
                    ZStack {
                        Circle().fill(state.isListening ? Color.orange : Color.white.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: state.isListening ? "waveform" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(state.isListening ? .black : .white)
                    }
                }
                .buttonStyle(.plain)
                .help(state.isListening ? "Stop & send" : "Talk to Debby (or hold ⌃⌥)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(size: 13, weight: state.isListening ? .regular : .medium))
                        .foregroundStyle(state.isListening && state.partial.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !state.agentLine.isEmpty {
                        Text(state.agentLine)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.isListening {
                    Waveform(levels: state.levels, height: 30, barWidth: 2)
                }
            }
            .frame(height: 64)

            HStack(spacing: 14) {
                if state.showNext && !state.isThinking && !state.isListening {
                    Button { state.submit("Done — what's the next step?") } label: {
                        Label("I did it", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Debby also advances automatically when it sees you click")
                }
                Spacer(minLength: 0)
                control(state.container == nil ? "viewfinder" : "viewfinder.circle.fill",
                        state.container == nil ? "Focus on an area of the screen" : "Clear focus area",
                        tint: state.container == nil ? .white : .orange) {
                    if state.container == nil { state.beginContainerSelection() } else { state.clearContainer() }
                }
                control("pencil.tip", drawing.isActive ? "Stop drawing" : "Draw on screen",
                        tint: drawing.isActive ? .orange : .white) { state.toggleDrawing() }
                control("square.and.pencil", "Start over") { state.newChat() }
                control("gearshape", "Settings") { SettingsWindow.show() }
                control("xmark.circle.fill", "End session") { state.dismiss() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    private var headline: String {
        if state.isListening { return state.partial.isEmpty ? "Listening…" : state.partial }
        if state.isThinking { return "Looking at your screen…" }
        if state.isSpeaking { return "" }  // text shown as a pill beside the cursor while speaking
        if !state.reply.isEmpty { return state.reply }
        if state.agentBusy { return "Agent working…" }
        return "Hold ⌃⌥ to talk"
    }

    private func control(_ icon: String, _ tip: String, tint: Color = .white,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

/// Live mic bars — the notch strip and the cursor visualiser share it.
struct Waveform: View {
    let levels: [CGFloat]
    var height: CGFloat = 26
    var barWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: barWidth) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(Color.orange)
                    .frame(width: barWidth, height: max(barWidth, levels[i] * height))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.06), value: levels)
    }
}

/// A real window, not a popover: a popover anchored to the notch dies the moment the
/// cursor leaves it and the notch collapses out from under it.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "HeyDebby Settings"
            w.isReleasedWhenClosed = false   // reopening must not resurrect a freed window
            w.level = .floating
            let host = NSHostingView(rootView: SettingsView())
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)  // accessory app: needed to type the API key
    }
}

/// Composio has no local CLI or API key here — it's a remote MCP server the agent CLIs
/// are already OAuth'd to. So we ask the CLI, which is the one thing holding that auth.
@MainActor
final class ComposioState: ObservableObject {
    @Published var output = ""   // whole CLI stream: banner, MCP call trace, errors
    @Published var result = ""   // just the answer — both CLIs print it last
    @Published var busy = false

    /// Last https link the agent printed — for Connect that's the authorization page.
    var link: URL? {
        let hay = result.isEmpty ? output : result
        guard let r = hay.range(of: "https://[^\\s\"'`()<>\\]]+", options: [.regularExpression, .backwards])
        else { return nil }
        return URL(string: String(hay[r]))
    }

    /// Slugs with a live connection, from the last refresh.
    @Published var connected: Set<String> = []
    /// Slug currently being connected, so its row can show the spinner.
    @Published var pending = ""

    func list() {
        pending = ""
        run("Using the Composio MCP tools, list my connected accounts. Reply with ONLY a "
            + "comma-separated list of the app slugs that have an ACTIVE connection — lowercase, no "
            + "spaces, no other words. If none are connected, reply exactly `none`.") { [weak self] answer in
            let slugs = answer.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "none" }
            self?.connected = Set(slugs)
        }
    }

    func connect(_ app: String) {
        pending = app
        run("Using the Composio MCP tools, start an OAuth connection for the app \"\(app)\". "
            + "Reply with ONLY the authorization URL, on its own line.") { _ in }
    }

    /// Always the claude CLI, whatever the chat backend is: `codex exec` auto-denies
    /// COMPOSIO_MANAGE_CONNECTIONS ("user cancelled MCP tool call") under every approval
    /// mode short of switching the sandbox off. claude takes a scoped --allowedTools.
    private func run(_ task: String, _ done: @escaping (String) -> Void) {
        guard !busy else { return }
        busy = true
        output = ""
        result = ""
        Task { [weak self] in
            let answer: String
            do {
                answer = try await shellOutput(
                    "claude -p \(shellQuote(task)) --output-format text --allowedTools mcp__composio")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self?.busy = false
                self?.output = error.localizedDescription
                return
            }
            guard let self else { return }
            self.busy = false
            self.output = answer
            self.result = answer
            done(answer)
        }
    }
}

struct ComposioSection: View {
    @StateObject private var composio = ComposioState()
    @State private var app = ""
    @State private var showOther = false

    /// Composio slugs, lowercase and unspaced — what its API actually wants.
    private static let apps = [
        ("gmail", "Gmail"), ("googlecalendar", "Google Calendar"), ("slack", "Slack"),
        ("notion", "Notion"), ("github", "GitHub"), ("googledrive", "Google Drive"),
        ("googlesheets", "Google Sheets"), ("googledocs", "Google Docs"), ("linear", "Linear"),
        ("jira", "Jira"), ("hubspot", "HubSpot"), ("discord", "Discord"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Connected apps").font(.headline)
                if composio.busy { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Refresh") { composio.list() }
                    .controlSize(.small).disabled(composio.busy)
            }
            VStack(spacing: 2) {
                ForEach(Self.apps, id: \.0) { slug, name in
                    row(slug: slug, name: name)
                }
            }
            .padding(.vertical, 4)
            .frame(width: 260)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            Button(showOther ? "Hide other app" : "Other app…") { showOther.toggle() }
                .buttonStyle(.link).controlSize(.small)
            if showOther {
                HStack(spacing: 6) {
                    TextField("composio slug, e.g. asana", text: $app)
                        .frame(width: 160)
                        .onSubmit { connectOther() }
                    Button("Connect", action: connectOther)
                        .controlSize(.small)
                        .disabled(composio.busy || app.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !composio.result.isEmpty {
                ScrollView {
                    Text(composio.result)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 260, height: 60)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else if composio.busy, let tail = composio.output.split(whereSeparator: \.isNewline).last {
                Text(tail).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).frame(width: 260, alignment: .leading)
            }
            // Never auto-opened: the URL comes out of agent output, so the user sees where it goes first.
            if let url = composio.link {
                Button("Authorize \(url.host ?? "") in browser →") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
            Text("Runs the `claude` CLI with Composio tools only. Takes a minute or two.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
        }
    }

    private func row(slug: String, name: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            if composio.busy && composio.pending == slug {
                ProgressView().controlSize(.mini)
            } else if composio.connected.contains(slug) {
                Label("connected", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green).labelStyle(.iconOnly)
                Text("connected").font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Connect") { composio.connect(slug) }
                    .controlSize(.small).disabled(composio.busy)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func connectOther() {
        let a = app.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty, !composio.busy else { return }
        composio.connect(a)
    }
}

struct SettingsView: View {
    @AppStorage("backend") private var backend = ""
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = "claude-sonnet-5"
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("geminiApiKey") private var geminiApiKey = ""
    @AppStorage("geminiModel") private var geminiModel = ""
    @AppStorage("openaiApiKey") private var openaiApiKey = ""
    @AppStorage("openaiModel") private var openaiModel = ""
    @AppStorage("voiceReplies") private var voiceReplies = true
    @AppStorage("voiceId") private var voiceId = ""
    @AppStorage("agentFullAccess") private var agentFullAccess = false
    @AppStorage("appControl") private var appControl = false

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let tier = v.quality == .premium ? " · premium" : v.quality == .enhanced ? " · enhanced" : ""
        return "\(v.name) (\(v.language))\(tier)"
    }

    // Two columns, not one stack: stacked, this was taller than a laptop screen.
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            brainColumn
            Divider()
            voiceColumn
        }
        .padding(16)
    }

    private var brainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brain").font(.headline)
            Picker("Brain", selection: $backend) {
                Text("Auto").tag("")
                Text("Codex (ChatGPT plan)").tag("codex")
                Text("Claude (Claude plan)").tag("claudecli")
                Text("Claude API key").tag("claude")
                Text("Gemini (Google AI)").tag("gemini")
                Text("OpenAI (GPT-5.6)").tag("openai")
            }
            .frame(width: 260)
            if resolveBackend(backend) == "claude" {
                SecureField("Anthropic API key (sk-ant-…)", text: $apiKey)
                    .frame(width: 260)
                TextField("Model", text: $model)
                    .frame(width: 260)
            } else if resolveBackend(backend) == "claudecli" {
                Text("Uses your Claude subscription via the `claude` CLI — no API key. "
                     + "Sends the screenshot as a file for the CLI to read.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            } else if resolveBackend(backend) == "gemini" {
                SecureField("Google AI API key (AIza…)", text: $geminiApiKey)
                    .frame(width: 260)
                TextField("Model (blank = \(Gemini.defaultModel))", text: $geminiModel)
                    .frame(width: 260)
                Text("Uses Google's Gemini with vision. Blank key falls back to GOOGLE_API_KEY "
                     + "or GEMINI_API_KEY. Get a key at aistudio.google.com.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            } else if resolveBackend(backend) == "openai" {
                SecureField("OpenAI API key (sk-…)", text: $openaiApiKey)
                    .frame(width: 260)
                TextField("Model (blank = \(OpenAI.defaultModel))", text: $openaiModel)
                    .frame(width: 260)
                Text("Streams, so Debby starts talking in about a second and draws each shape "
                     + "as she describes it. Blank key falls back to OPENAI_API_KEY. "
                     + "gpt-5.6-terra and gpt-5.6-sol are stronger and slower.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
            } else {
                TextField("Codex model (blank = codex CLI's default)", text: $codexModel)
                    .frame(width: 260)
                Text("Uses your ChatGPT subscription via `codex login`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Agents: full access (skips sandbox/permissions — risky)", isOn: $agentFullAccess)
            Toggle("Let Debby control apps (volume, Spotify, menus)", isOn: $appControl)
            Text("Debby runs short AppleScript commands. macOS will ask permission the first "
                 + "time she touches each app, in Privacy & Security → Automation.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            Text("Once you allow an app, Debby can control it fully, not just the one thing "
                 + "you asked for. Worth leaving off unless you want that.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Button("Open log…") { DebbyLog.reveal() }
                Text("every CLI run, verbatim").font(.caption).foregroundStyle(.secondary)
            }
            Button("Quit HeyDebby") { NSApp.terminate(nil) }
        }
        .frame(width: 280)
    }

    private var voiceColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice & apps").font(.headline)
            Toggle("Speak replies aloud", isOn: $voiceReplies)
            Picker("Voice", selection: $voiceId) {
                Text("Auto (best installed)").tag("")
                ForEach(SpeechOutput.candidateVoices(), id: \.identifier) { v in
                    Text(voiceLabel(v)).tag(v.identifier)
                }
            }
            .frame(width: 260)
            Button("Get better voices…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!)
            }
            Text("Download a Premium voice under Spoken Content → System Voice → Manage Voices; Debby auto-picks it.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            Divider()
            ComposioSection()
        }
        .frame(width: 280)
    }
}

// MARK: - Container (focus area) selection + outline

final class SelectorWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }  // 53 = esc
    }
}

@MainActor
enum RegionSelector {
    private static var window: SelectorWindow?

    /// Full-screen drag-to-select. Calls back with a normalized top-left-origin rect, or nil on cancel.
    static func begin(on screen: NSScreen, onDone: @escaping (CGRect?) -> Void) {
        close()
        let w = SelectorWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.onCancel = { close(); onDone(nil) }
        w.contentView = NSHostingView(rootView: RegionSelectView(size: screen.frame.size) { rect in
            close()
            onDone(rect)
        })
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }
}

struct RegionSelectView: View {
    let size: CGSize
    let onDone: (CGRect?) -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
            if let r = rect {
                Rectangle().path(in: r).fill(Color.orange.opacity(0.1))
                Rectangle().path(in: r).stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            }
            VStack {
                Text("Drag to select a focus area · esc to cancel")
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 60)
                Spacer()
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if start == nil { start = v.startLocation }
                    current = v.location
                }
                .onEnded { _ in
                    if let r = rect, r.width > 20, r.height > 20 {
                        onDone(CGRect(x: r.minX / size.width, y: r.minY / size.height,
                                      width: r.width / size.width, height: r.height / size.height))
                    } else {
                        onDone(nil)
                    }
                }
        )
    }
}

@MainActor
final class ContainerOutline {
    private var window: NSWindow?

    func show(_ rect: CGRect, on screen: NSScreen) {
        hide()
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: ContainerOutlineView(rect: rect, size: screen.frame.size))
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

struct ContainerOutlineView: View {
    let rect: CGRect  // normalized
    let size: CGSize

    var body: some View {
        let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                       width: rect.width * size.width, height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Color.clear
            Rectangle().path(in: r)
                .stroke(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            Text("👆 focus area")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
                .offset(x: r.minX + 6, y: max(r.minY - 20, 4))
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Debby pointer (companion cursor, always on screen)

@MainActor
final class DebbyPointer {
    private weak var state: AppState?
    private var window: NSWindow?
    private var timer: Timer?
    private var pos = CGPoint.zero
    private var highlightTarget: CGPoint?
    private var tourTask: Task<Void, Never>?

    // Window is wide enough to hold the triangle + a speech pill to its right.
    private let windowSize = CGSize(width: 400, height: 60)

    // Triangle is 32×32, vertically centered in the 60-tall window (AppKit y-up).
    // After -45° rotation the apex lands at (16-r, windowHeight/2+r).
    private var tip: CGPoint {
        let r: CGFloat = 9 * 0.7071
        return CGPoint(x: 16 - r, y: windowSize.height / 2 + r)
    }

    func start(state: AppState) {
        guard window == nil else { return }
        self.state = state
        let w = NSWindow(contentRect: NSRect(origin: NSEvent.mouseLocation, size: windowSize),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: DebbyPointerView().environmentObject(state))
        w.orderFrontRegardless()
        window = w
        pos = NSEvent.mouseLocation
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let w = window else { return }
        let mouse = NSEvent.mouseLocation
        state?.trackMouse(mouse)
        let tipTarget = highlightTarget ?? CGPoint(x: mouse.x + 18, y: mouse.y - 18)
        let desired = CGPoint(x: tipTarget.x - tip.x, y: tipTarget.y - tip.y)
        if abs(desired.x - pos.x) < 0.3 && abs(desired.y - pos.y) < 0.3 { return }
        pos.x += (desired.x - pos.x) * 0.18
        pos.y += (desired.y - pos.y) * 0.18
        w.setFrameOrigin(pos)
    }

    func highlight(_ points: [CGPoint]) {
        tourTask?.cancel()
        guard !points.isEmpty else { return }
        tourTask = Task { [weak self] in
            for (i, p) in points.enumerated() {
                guard !Task.isCancelled else { return }
                self?.highlightTarget = p
                if i < points.count - 1 { try? await Task.sleep(nanoseconds: 1_400_000_000) }
            }
        }
    }

    func endHighlight() {
        tourTask?.cancel()
        tourTask = nil
        highlightTarget = nil
    }
}

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct DebbyPointerView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Hidden entirely during drawing so the system crosshair is unobstructed.
        if !state.isDrawing {
            HStack(alignment: .center, spacing: 10) {
                // Triangle cursor (or waveform while listening) — 32×32 box.
                ZStack {
                    if state.isListening {
                        CursorVisualizer(levels: state.levels)
                    } else {
                        TriangleShape()
                            .fill(Color.orange)
                            .overlay(TriangleShape().stroke(.white.opacity(0.9), lineWidth: 1))
                            .frame(width: 18, height: 18)
                            .rotationEffect(.degrees(-45))
                            .shadow(color: .orange.opacity(0.9), radius: 3)
                            .shadow(color: .orange.opacity(0.45), radius: 7)
                    }
                }
                .frame(width: 32, height: 32)

                // Speech pill — live subtitle beside the cursor while Debby speaks.
                if state.isSpeaking, !state.speakingText.isEmpty {
                    Text(state.speakingText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.86), in: Capsule())
                        .overlay(Capsule().strokeBorder(.orange.opacity(0.5), lineWidth: 1))
                        .frame(maxWidth: 310, alignment: .leading)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .frame(width: 400, height: 60, alignment: .leading)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: state.isSpeaking)
        }
    }
}

/// While Debby listens the triangle becomes this: 5 mic-driven bars, same spot, same 18pt.
struct CursorVisualizer: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.suffix(5).enumerated()), id: \.offset) { _, l in
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 2, height: max(3, 18 * l))
            }
        }
        .frame(width: 18, height: 18)
        .shadow(color: .orange.opacity(0.9), radius: 3)
        .shadow(color: .orange.opacity(0.45), radius: 7)
        .animation(.linear(duration: 0.06), value: levels)
    }
}

// MARK: - Screen-drawing overlay (click-through, points at things)

@MainActor
final class OverlayController: ObservableObject {
    @Published var annotations: [Annotation] = []
    var onHide: (() -> Void)?
    private var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    // Show all annotations at once (used when voice is off).
    func show(_ anns: [Annotation], on screen: NSScreen) {
        closeWindow()
        annotations = anns
        openWindow(on: screen)
        scheduleAutoHide()
    }

    /// A streamed lesson doesn't know it will point at anything until the POINT arrives,
    /// so the caller checks this instead of opening an empty window on every reply.
    var isOpen: Bool { window != nil }

    // Open the overlay with no annotations yet; call addAnnotation() to reveal progressively.
    func showEmpty(on screen: NSScreen) {
        closeWindow()
        annotations = []
        openWindow(on: screen)
    }

    // Append one annotation; the overlay view animates it in. Resets the auto-hide timer.
    func addAnnotation(_ ann: Annotation) {
        annotations.append(ann)
        scheduleAutoHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        closeWindow()
        annotations = []
        onHide?()
    }

    private func closeWindow() {
        hideTask?.cancel()
        hideTask = nil
        window?.orderOut(nil)
        window = nil
    }

    private func openWindow(on screen: NSScreen) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: OverlayView(controller: self, size: screen.frame.size))
        w.orderFrontRegardless()
        window = w
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { self?.hide() }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var controller: OverlayController
    let size: CGSize
    // Tracks which annotation indices have completed their draw-on animation.
    @State private var drawnIndices: Set<Int> = []
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(Array(controller.annotations.enumerated()), id: \.offset) { i, a in
                let drawn = drawnIndices.contains(i)
                Group {
                    if let w = a.w, let h = a.h, w > 0.001, h > 0.001 {
                        areaMark(a, w: w, h: h, drawn: drawn)
                    } else {
                        pointMark(a, drawn: drawn)
                    }
                }
                // Each annotation triggers its own draw-on animation when it first appears.
                .onAppear {
                    withAnimation(.easeOut(duration: 0.55)) { _ = drawnIndices.insert(i) }
                }
            }

            // Subtitle pill row at the bottom — closed-caption style.
            let labels = controller.annotations.map { $0.label }.filter { !$0.isEmpty }
            if !labels.isEmpty {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(labels, id: \.self) { label in
                            subtitlePill(label)
                        }
                    }
                    .padding(.bottom, 56)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).delay(0.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func pointMark(_ a: Annotation, drawn: Bool) -> some View {
        ZStack {
            Circle()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: pulse ? 64 : 44, height: pulse ? 64 : 44)
                .shadow(color: .orange.opacity(0.6), radius: 8)
            annotationLabel(a.label)
                .offset(y: 48)
                .opacity(drawn ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.4), value: drawn)
        }
        .position(x: a.x * size.width, y: a.y * size.height)
    }

    private func areaMark(_ a: Annotation, w: Double, h: Double, drawn: Bool) -> some View {
        let rw = w * size.width
        let rh = h * size.height
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: rw, height: rh)
                .shadow(color: .orange.opacity(pulse ? 0.8 : 0.35), radius: pulse ? 12 : 6)
            annotationLabel(a.label)
                .offset(y: rh / 2 + 18)
                .opacity(drawn ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.6), value: drawn)
        }
        .position(x: (a.x + w / 2) * size.width, y: (a.y + h / 2) * size.height)
    }

    // Floating label near the annotated element.
    private func annotationLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(.orange, lineWidth: 1.5))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 4)
    }

    // Closed-caption style pill at the bottom of the screen.
    private func subtitlePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.black.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.8), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 6)
    }
}

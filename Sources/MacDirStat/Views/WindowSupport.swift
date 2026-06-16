import SwiftUI
import AppKit
import QuartzCore

/// Resolves the hosting `NSWindow` so we can configure transparency and resize
/// it when side panels toggle. Place via `.background(WindowAccessor { ... })`.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onResolve(window) }
    }
}

/// A behind-window vibrancy view. Because it blends with what's *behind the
/// window* (the desktop), side panels backed by this read as frosted glass over
/// the wallpaper rather than over the opaque map.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

enum PanelSide { case left, right }

/// Computes the window frame after a panel toggle: the window grows/shrinks by
/// `width` on one side so the center (map) keeps its size. The left panel
/// extends the window leftward, the right panel rightward. If the grown frame
/// would spill off-screen, the whole window is nudged back toward center so the
/// panel still fits.
@MainActor
func panelTargetFrame(_ window: NSWindow, side: PanelSide, showing: Bool, width: CGFloat) -> NSRect {
    var frame = window.frame
    let delta = showing ? width : -width

    switch side {
    case .left:
        frame.origin.x -= delta
        frame.size.width += delta
    case .right:
        frame.size.width += delta
    }

    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
        if frame.width > visible.width { frame.size.width = visible.width }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
    }

    return frame
}

/// Animates ONLY the window frame off a timer. The panel width is left to
/// SwiftUI layout: during the toggle the center (map) is pinned to a fixed width
/// and the toggling panel is flexible, so each window-frame step produces a
/// single layout pass where the panel absorbs the whole size change and the map
/// stays constant (no whipsaw, no treemap recompute). Calls `completion` at the
/// end so the view can unpin.
@MainActor
final class PanelResizeAnimator: NSObject {
    private var timer: Timer?
    private weak var window: NSWindow?
    private var fromFrame: NSRect = .zero
    private var toFrame: NSRect = .zero
    private var startTime: CFTimeInterval = 0
    private var duration: Double = 0.24
    private var completion: (() -> Void)?

    func animate(window: NSWindow, side: PanelSide, showing: Bool, width: CGFloat,
                 duration: Double = 0.24, completion: @escaping () -> Void) {
        timer?.invalidate()
        self.window = window
        self.duration = duration
        self.completion = completion
        fromFrame = window.frame
        toFrame = panelTargetFrame(window, side: side, showing: showing, width: width)
        startTime = CACurrentMediaTime()

        // Selector-based timer (no @Sendable closure) fires on the main runloop.
        let t = Timer(timeInterval: 1.0 / 120.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common) // keep animating during UI tracking
        timer = t
    }

    @objc private func tick() {
        guard let window else { finish(); return }
        let progress = min(1.0, max(0.0, (CACurrentMediaTime() - startTime) / duration))
        let e = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        window.setFrame(lerp(fromFrame, toFrame, e), display: true)
        if progress >= 1 {
            window.setFrame(toFrame, display: true)
            finish()
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        let c = completion
        completion = nil
        c?()
    }

    private func lerp(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }
}

/// Sizes a side panel: flexible (fills leftover up to `fullWidth`) while its
/// window edge is being animated, otherwise a fixed `fullWidth`/0.
struct PanelWidth: ViewModifier {
    let flexible: Bool
    let fullWidth: CGFloat
    let shown: Bool
    let alignment: Alignment

    func body(content: Content) -> some View {
        if flexible {
            content.frame(maxWidth: fullWidth, alignment: alignment)
        } else {
            content.frame(width: shown ? fullWidth : 0, alignment: alignment)
        }
    }
}

/// Pins the center to a fixed width during a panel toggle (so the map can't
/// reflow); flexible otherwise.
struct CenterWidth: ViewModifier {
    let pinned: CGFloat?

    func body(content: Content) -> some View {
        if let pinned {
            content.frame(width: pinned, alignment: .center)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

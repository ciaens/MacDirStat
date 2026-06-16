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

/// Drives a panel toggle off a single timer so the window resize and the panel's
/// visible width advance in lockstep — `window − panel` (the map) is constant
/// every frame, with no second animation clock to drift against. `sidebarFraction`
/// / `inspectorFraction` (0…1) feed the panels' clipped width in the view.
@MainActor
@Observable
final class PanelResizeAnimator: NSObject {
    var sidebarFraction: CGFloat = 1
    var inspectorFraction: CGFloat = 1

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var fromFrame: NSRect = .zero
    @ObservationIgnored private var toFrame: NSRect = .zero
    @ObservationIgnored private var fromFraction: CGFloat = 0
    @ObservationIgnored private var toFraction: CGFloat = 0
    @ObservationIgnored private var startTime: CFTimeInterval = 0
    @ObservationIgnored private var duration: Double = 0.24
    @ObservationIgnored private var side: PanelSide = .left

    func animate(window: NSWindow, side: PanelSide, showing: Bool, width: CGFloat, duration: Double = 0.24) {
        timer?.invalidate()
        self.window = window
        self.side = side
        self.duration = duration
        fromFrame = window.frame
        toFrame = panelTargetFrame(window, side: side, showing: showing, width: width)
        fromFraction = (side == .left) ? sidebarFraction : inspectorFraction
        toFraction = showing ? 1 : 0
        startTime = CACurrentMediaTime()

        // Selector-based timer (no @Sendable closure) fires on the main runloop.
        let t = Timer(timeInterval: 1.0 / 120.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common) // keep animating during UI tracking
        timer = t
    }

    func setInstant(side: PanelSide, showing: Bool) {
        timer?.invalidate()
        if side == .left { sidebarFraction = showing ? 1 : 0 } else { inspectorFraction = showing ? 1 : 0 }
    }

    @objc private func tick() {
        guard let window else { timer?.invalidate(); return }
        let progress = min(1.0, max(0.0, (CACurrentMediaTime() - startTime) / duration))
        let e = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
        window.setFrame(lerp(fromFrame, toFrame, e), display: true)
        let fraction = fromFraction + (toFraction - fromFraction) * e
        if side == .left { sidebarFraction = fraction } else { inspectorFraction = fraction }

        if progress >= 1 {
            timer?.invalidate()
            window.setFrame(toFrame, display: true)
            if side == .left { sidebarFraction = toFraction } else { inspectorFraction = toFraction }
        }
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

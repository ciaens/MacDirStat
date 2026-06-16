import SwiftUI
import AppKit

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
        // AppKit origin is bottom-left; extend leftward by moving origin.
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

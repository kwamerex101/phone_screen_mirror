import AppKit
import iMirrorCore

func adaptPreviewWindow(_ window: NSWindow, to size: NSSize) {
    let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
    let available = window.contentRect(forFrameRect: visible).size
    let current = window.contentView?.bounds.size ?? size
    let target = adaptedPreviewSize(current: current, frame: size, available: available)
    window.contentAspectRatio = size
    if !window.styleMask.contains(.fullScreen) {
        window.setContentSize(target)
        var rect = window.frame
        rect.origin.x = max(visible.minX, min(rect.minX, visible.maxX - rect.width))
        rect.origin.y = max(visible.minY, min(rect.minY, visible.maxY - rect.height))
        window.setFrame(rect, display: true)
    }
}

import AppKit

/// Keep construction in one place so the real AppKit window lifetime can be
/// exercised in an isolated application event loop.
func makeMainWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    // AppDelegate owns this window through ARC. AppKit must not release that
    // ownership on close while queued video/status callbacks can still run.
    window.isReleasedWhenClosed = false
    return window
}

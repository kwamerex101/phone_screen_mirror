// ScreenshotThumbnail.swift
// A macOS-style floating thumbnail shown after a screenshot is saved. Click to
// open the file, drag it into Finder/Slack/editors, or let it fade out.

import AppKit

/// Borderless panel that never takes key or main status, so it can't steal
/// focus from the mirror window.
private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The thumbnail content: image, rounded border, hover tracking, click and drag.
private final class ThumbnailView: NSView, NSDraggingSource {
    var image: NSImage
    var fileURL: URL
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?   // true when the drop was accepted

    private var mouseDownPoint: NSPoint?
    private var dragStarted = false
    private let dragThreshold: CGFloat = 3

    init(frame: NSRect, image: NSImage, fileURL: URL) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor

        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Screenshot preview, drag to copy, click to open")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // The panel is non-key, so accept the very first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > dragThreshold else { return }
        dragStarted = true

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        onDragBegan?()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragStarted else { return }
        onClick?()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        onDragEnded?(operation != [])
    }
}

final class ScreenshotThumbnail {
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var dismissTimer: Timer?
    private var isDragging = false
    /// Bumped on every show/dismiss so a stale fade-out completion can't tear
    /// down a newer panel.
    private var generation = 0

    private let displayHeight: CGFloat = 160
    private let maxWidthFraction: CGFloat = 0.45
    private let rightInset: CGFloat = 12
    private let bottomInset: CGFloat = 40   // clears the 1-2 line status strip
    private let slideOffset: CGFloat = 16
    private let animationDuration: TimeInterval = 0.2
    private let lifetime: TimeInterval = 6

    func show(image: CGImage, fileURL: URL, over parent: NSWindow) {
        dismissNow()
        generation += 1
        let gen = generation

        // Fit to 160pt tall; cap width at 45% of the parent's content width.
        let aspect = CGFloat(image.width) / max(CGFloat(image.height), 1)
        let contentRect = parent.contentRect(forFrameRect: parent.frame)
        var height = displayHeight
        var width = height * aspect
        let maxWidth = contentRect.width * maxWidthFraction
        if width > maxWidth {
            width = maxWidth
            height = width / max(aspect, 0.001)
        }
        let size = NSSize(width: width.rounded(), height: height.rounded())

        // Bottom-right of the content area, clamped inside the parent frame.
        var origin = NSPoint(x: contentRect.maxX - rightInset - size.width,
                             y: contentRect.minY + bottomInset)
        origin.x = min(max(origin.x, parent.frame.minX), parent.frame.maxX - size.width)
        origin.y = min(max(origin.y, parent.frame.minY), parent.frame.maxY - size.height)
        let finalFrame = NSRect(origin: origin, size: size)

        let nsImage = NSImage(cgImage: image, size: size)
        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size), image: nsImage, fileURL: fileURL)
        view.onClick = { [weak self] in
            NSWorkspace.shared.open(fileURL)
            self?.dismiss()
        }
        view.onHover = { [weak self] inside in
            guard let self, !self.isDragging else { return }
            if inside { self.cancelTimer() } else { self.startTimer() }
        }
        view.onDragBegan = { [weak self] in
            guard let self else { return }
            self.isDragging = true
            self.cancelTimer()
            self.panel?.alphaValue = 0
        }
        view.onDragEnded = { [weak self] accepted in
            guard let self else { return }
            self.isDragging = false
            if accepted {
                self.dismissNow()
            } else {
                self.panel?.alphaValue = 1
                self.startTimer()
            }
        }

        let p = ThumbnailPanel(contentRect: finalFrame,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.contentView = view

        // Start transparent and a little to the right, then slide in while fading in.
        // Reduce Motion: fade only, no frame offset.
        let offset = reduceMotion ? 0 : slideOffset
        p.setFrame(finalFrame.offsetBy(dx: offset, dy: 0), display: false)
        p.alphaValue = 0
        parent.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        panel = p
        parentWindow = parent

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = iMirrorEaseOut
            p.animator().setFrame(finalFrame, display: true)
            p.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            // Skip if replaced or dismissed mid-animation.
            guard let self, self.generation == gen else { return }
            self.startTimer()
        }
    }

    // MARK: Dismissal

    /// Fade out while sliding right, then detach and hide the panel.
    private func dismiss() {
        cancelTimer()
        guard let p = panel else { return }
        panel = nil
        generation += 1
        let parent = parentWindow
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if !reduceMotion {
                p.animator().setFrame(p.frame.offsetBy(dx: slideOffset, dy: 0), display: true)
            }
            p.animator().alphaValue = 0
        } completionHandler: {
            parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    /// Tear down immediately with no animation (replacement or accepted drop).
    private func dismissNow() {
        cancelTimer()
        generation += 1
        isDragging = false
        guard let p = panel else { return }
        panel = nil
        parentWindow?.removeChildWindow(p)
        p.orderOut(nil)
    }

    // MARK: Timer

    private func startTimer() {
        cancelTimer()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func cancelTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
}

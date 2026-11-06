import CoreGraphics

/// Video pixels and WDA points may have different scales, but must describe
/// the same display shape before input can be mapped safely.
public func displayShapesMatch(frame: CGSize, logical: CGSize) -> Bool {
    guard frame.width.isFinite, frame.height.isFinite,
          logical.width.isFinite, logical.height.isFinite,
          frame.width > 0, frame.height > 0, logical.width > 0, logical.height > 0 else { return false }
    let relativeRatio = (frame.width / frame.height) / (logical.width / logical.height)
    return abs(relativeRatio - 1) < 0.02 // allow JPEG scaling/rounding
}

/// Preserve the user's preview area across rotation or a display change, while
/// fitting the new shape on the Mac. No device model or fixed pixel scale.
public func adaptedPreviewSize(current: CGSize, frame: CGSize, available: CGSize) -> CGSize {
    guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite,
          available.width > 0, available.height > 0 else { return current }
    let ratio = frame.width / frame.height
    let area = max(1, current.width * current.height)
    let width = max(260, max(200 * ratio, (area * ratio).squareRoot()))
    let height = width / ratio
    let scale = min(1, min(available.width / width, available.height / height))
    return CGSize(width: width * scale, height: height * scale)
}

/// Map a point in the preview (view coordinates, y-up) to a device point in WDA
/// logical points (y-down), given the displayed video rect within the view and
/// the device's logical size. Returns nil if the point is outside the video.
public func mapToDevice(viewPoint p: CGPoint, videoRect: CGRect, deviceSize: CGSize) -> CGPoint? {
    guard videoRect.width > 1, videoRect.height > 1 else { return nil }
    let nx = (p.x - videoRect.minX) / videoRect.width
    let nyUp = (p.y - videoRect.minY) / videoRect.height
    guard nx >= 0, nx <= 1, nyUp >= 0, nyUp <= 1 else { return nil }   // outside video
    let ny = 1 - nyUp   // view is y-up, device is y-down
    return CGPoint(x: nx * deviceSize.width, y: ny * deviceSize.height)
}

/// Evenly thin a path to at most `max` points (keeps first + last) so a long drag
/// doesn't produce an oversized WDA action payload.
public func downsample(_ points: [CGPoint], max: Int) -> [CGPoint] {
    guard points.count > max, max >= 2 else { return points }
    let step = Double(points.count - 1) / Double(max - 1)
    var out: [CGPoint] = []
    for i in 0..<max { out.append(points[Int((Double(i) * step).rounded())]) }
    return out
}

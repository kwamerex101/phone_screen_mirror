import CoreGraphics

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

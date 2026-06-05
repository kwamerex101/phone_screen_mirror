#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a simple, clean iMirror icon:
// a dark rounded panel (a phone) with a green status ring, matching the app's
// health-dot theme. Pure AppKit; no assets.

import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size

    // Background: rounded squircle with a subtle vertical gradient.
    let margin = s * 0.06
    let bgRect = NSRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: s*0.22, yRadius: s*0.22)
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1),
                                   NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!
    grad.draw(in: bg, angle: -90)

    // Phone body (rounded rect, centered, portrait).
    let pw = s * 0.34, ph = s * 0.56
    let phoneRect = NSRect(x: (s-pw)/2, y: (s-ph)/2, width: pw, height: ph)
    let phone = NSBezierPath(roundedRect: phoneRect, xRadius: pw*0.18, yRadius: pw*0.18)
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill(); phone.fill()
    // Screen
    let inset = pw * 0.08
    let screen = NSBezierPath(roundedRect: phoneRect.insetBy(dx: inset, dy: inset*1.6),
                              xRadius: pw*0.12, yRadius: pw*0.12)
    NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1).setFill(); screen.fill()

    // Green status ring (bottom-right), echoing the health dot.
    let d = s * 0.20
    let dot = NSRect(x: s - margin - d*1.15, y: margin + d*0.15, width: d, height: d)
    NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -d*0.12, dy: -d*0.12)).fill()
    NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let here = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent().deletingLastPathComponent()   // …/ios-mirror
let iconset = here.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let png = drawIcon(size: px).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let icns = here.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run(); p.waitUntilExit()
print("wrote \(icns.path)")

#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — the iMirror icon: a phone with a bright
// screen and a Mac-style cursor on it (mirror + control) plus a green "live" dot,
// on a deep gradient squircle. Pure AppKit; no external assets.

import AppKit

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    func rrect(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
    }

    // Background squircle, indigo → near-black.
    let m = s * 0.06
    let bgRect = NSRect(x: m, y: m, width: s - 2*m, height: s - 2*m)
    NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.22, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.16, alpha: 1)])!
        .draw(in: rrect(bgRect, s*0.225), angle: -90)

    // Faint "mirror" echo: a second phone shadow offset behind the main one.
    let pw = s * 0.34, ph = s * 0.58
    let cx = s/2, cy = s/2
    let echo = NSRect(x: cx - pw/2 + s*0.045, y: cy - ph/2 - s*0.02, width: pw, height: ph)
    NSColor(white: 1, alpha: 0.10).setFill(); rrect(echo, pw*0.2).fill()

    // Main phone body.
    let phoneRect = NSRect(x: cx - pw/2, y: cy - ph/2, width: pw, height: ph)
    NSColor(white: 0.96, alpha: 1).setFill(); rrect(phoneRect, pw*0.2).fill()

    // Screen with a teal → blue gradient.
    let inset = pw * 0.075
    let screenRect = phoneRect.insetBy(dx: inset, dy: inset * 1.7)
    NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.80, blue: 0.86, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.42, blue: 0.95, alpha: 1)])!
        .draw(in: rrect(screenRect, pw*0.12), angle: -65)

    // Mac-style cursor arrow on the screen (= control from the Mac).
    let a = s * 0.085
    let ox = cx - a*0.15, oy = cy + a*0.6
    let cur = NSBezierPath()
    cur.move(to: NSPoint(x: ox, y: oy))
    cur.line(to: NSPoint(x: ox, y: oy - a*1.6))
    cur.line(to: NSPoint(x: ox + a*0.42, y: oy - a*1.18))
    cur.line(to: NSPoint(x: ox + a*0.66, y: oy - a*1.62))
    cur.line(to: NSPoint(x: ox + a*0.92, y: oy - a*1.5))
    cur.line(to: NSPoint(x: ox + a*0.66, y: oy - a*1.06))
    cur.line(to: NSPoint(x: ox + a*1.18, y: oy - a*1.02))
    cur.close()
    NSColor.white.setFill()
    NSColor(white: 0, alpha: 0.25).setStroke(); cur.lineWidth = max(1, s*0.004)
    cur.fill(); cur.stroke()

    // Green "live" dot, top-right of the phone, ringed for contrast.
    let d = s * 0.15
    let dot = NSRect(x: phoneRect.maxX - d*0.55, y: phoneRect.maxY - d*0.55, width: d, height: d)
    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -d*0.16, dy: -d*0.16)).fill()
    NSColor.systemGreen.setFill(); NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let here = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = here.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                   ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                   ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let png = drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let icns = here.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run(); p.waitUntilExit()
print("wrote \(icns.path)")

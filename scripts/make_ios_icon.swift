#!/usr/bin/env swift
// Generates a 1024x1024 iOS app-icon PNG for the rebranded WDA runner — the same
// iMirror artwork as scripts/make_icon.swift (phone + Mac cursor + green live dot
// on an indigo→black field), but FULL-BLEED and OPAQUE: iOS masks its own squircle
// corners and rejects icons with an alpha channel, so we fill the whole square.
//
// Usage: swift scripts/make_ios_icon.swift <output.png>

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

    // Full-bleed background gradient, indigo → near-black (no margin; iOS masks corners).
    NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.22, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.16, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)

    let pw = s * 0.34, ph = s * 0.58
    let cx = s/2, cy = s/2

    // Faint "mirror" echo behind the main phone.
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

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/ios-appicon-1024.png"
// Composite onto an opaque bitmap so the PNG carries no meaningful alpha.
let rep = drawIcon(size: 1024)
let png = rep.representation(using: .png, properties: [.interlaced: false])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

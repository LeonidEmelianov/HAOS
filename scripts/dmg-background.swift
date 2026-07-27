#!/usr/bin/env swift
//
// Renders the disk image window background at 1x and 2x.
//
// Kept as source rather than a checked-in PNG so the layout constants live in
// one place: the icon positions make-dmg.sh hands to Finder must line up with
// the halos and arrow drawn here, and a binary asset would drift from them.
//
// Usage: swift scripts/dmg-background.swift <output-directory>
// Writes background.png and background@2x.png.

import AppKit

/// Window content size in points. make-dmg.sh sizes the Finder window to match.
let canvas = NSSize(width: 700, height: 420)

/// Where Finder puts the two icons, in points from the top-left corner.
/// Mirrored in make-dmg.sh.
let appIconCenter = NSPoint(x: 190, y: 215)
let applicationsIconCenter = NSPoint(x: 510, y: 215)

/// Home Assistant blue, taken from the app icon.
let brand = NSColor(srgbRed: 0.10, green: 0.74, blue: 0.95, alpha: 1)
let ink = NSColor(srgbRed: 0.06, green: 0.20, blue: 0.28, alpha: 1)

/// AppKit draws from the bottom left; every position above is measured from
/// the top left, the way Finder counts.
func flipped(_ point: NSPoint) -> NSPoint {
    NSPoint(x: point.x, y: canvas.height - point.y)
}

func drawBackdrop() {
    NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.99, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.87, green: 0.95, blue: 0.99, alpha: 1),
    ])?.draw(in: NSRect(origin: .zero, size: canvas), angle: -90)
}

/// A soft pool of brand color under an icon, so the icons read as placed
/// rather than floating on a flat wash.
func drawHalo(at point: NSPoint, radius: CGFloat, strength: CGFloat) {
    let center = flipped(point)
    NSGradient(colors: [
        brand.withAlphaComponent(strength),
        brand.withAlphaComponent(0),
    ])?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

/// The drag gesture: a dashed rule from the app to the Applications folder,
/// ending in a chevron. Dashes read as "move this there" more clearly than a
/// solid line, which looks like a divider.
func drawArrow(from startX: CGFloat, to endX: CGFloat, y: CGFloat) {
    let baseline = canvas.height - y
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: startX, y: baseline))
    tail.line(to: NSPoint(x: endX - 16, y: baseline))
    tail.lineWidth = 4
    tail.lineCapStyle = .round
    tail.setLineDash([2, 12], count: 2, phase: 0)
    brand.withAlphaComponent(0.6).setStroke()
    tail.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: endX - 24, y: baseline + 14))
    head.line(to: NSPoint(x: endX, y: baseline))
    head.line(to: NSPoint(x: endX - 24, y: baseline - 14))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    brand.setStroke()
    head.stroke()
}

func draw(_ text: String, font: NSFont, color: NSColor, centeredAt y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let string = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style,
    ])
    let height = string.size().height
    string.draw(in: NSRect(x: 0, y: canvas.height - y - height / 2,
                           width: canvas.width, height: height))
}

func render(scale: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("could not allocate the bitmap") }
    // Drawing then happens in points; the rep scales it up on its own.
    rep.size = canvas

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    drawBackdrop()
    drawHalo(at: appIconCenter, radius: 115, strength: 0.34)
    drawHalo(at: applicationsIconCenter, radius: 105, strength: 0.18)
    drawArrow(from: appIconCenter.x + 95, to: applicationsIconCenter.x - 95, y: appIconCenter.y)

    draw("HAOS", font: .systemFont(ofSize: 34, weight: .bold), color: ink, centeredAt: 62)
    draw("Home Assistant OS, running on your Mac",
         font: .systemFont(ofSize: 15, weight: .regular),
         color: ink.withAlphaComponent(0.65), centeredAt: 94)
    draw("Drag HAOS into Applications",
         font: .systemFont(ofSize: 13, weight: .medium),
         color: ink.withAlphaComponent(0.55), centeredAt: 348)
    draw("Requires macOS 27 or later on Apple Silicon",
         font: .systemFont(ofSize: 11, weight: .regular),
         color: ink.withAlphaComponent(0.38), centeredAt: 386)

    NSGraphicsContext.current?.flushGraphics()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode the PNG")
    }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift <output-directory>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try render(scale: 1, to: directory.appendingPathComponent("background.png"))
try render(scale: 2, to: directory.appendingPathComponent("background@2x.png"))

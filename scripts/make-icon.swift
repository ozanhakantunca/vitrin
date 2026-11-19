#!/usr/bin/env swift
// Draws the Vitrin app icon and builds Resources/AppIcon/Vitrin.icns.
// Usage: swift scripts/make-icon.swift <outdir>
//   <outdir>/Vitrin.iconset/*.png, <outdir>/Vitrin.icns, <outdir>/Vitrin.png (1024 px preview)
import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a)
}

/// Superellipse ("squircle") path approximating the Big Sur icon shape.
func squircle(_ r: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon in a 1024x1024 design space (y up) into `ctx`.
func drawIcon(_ ctx: CGContext, pixels: Int) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.38))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x1B2A6B))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient background (teal top -> indigo bottom).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x1FA3A8), rgb(0x2D3FA0), rgb(0x2A2278)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft top highlight.
    let hl = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    // Thin inner rim.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Window cards: 2x2 grid.
    let gridMin: CGFloat = 215, gap: CGFloat = 50
    let cardW = (1024 - 2 * gridMin - gap) / 2          // 267
    let cardH: CGFloat = cardW * 0.86
    let totalH = cardH * 2 + gap
    let top = 512 + totalH / 2
    let selected = (col: 1, row: 0)                      // top-right
    let showDots = pixels >= 48

    for row in 0..<2 {
        for col in 0..<2 {
            let x = gridMin + CGFloat(col) * (cardW + gap)
            let y = top - CGFloat(row + 1) * cardH - CGFloat(row) * gap
            let rect = CGRect(x: x, y: y, width: cardW, height: cardH)
            let isSel = (col == selected.col && row == selected.row)
            let radius: CGFloat = 40
            let path = roundedRect(rect, radius)

            // Selected card: bright accent border + glow, drawn behind the card.
            if isSel {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 36, color: rgb(0xFFC24D, 0.85))
                ctx.addPath(roundedRect(rect.insetBy(dx: -15, dy: -15), radius + 15))
                ctx.setFillColor(rgb(0xFFC24D))
                ctx.fillPath()
                ctx.restoreGState()
            }

            // Shadow + fill.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x050A30, isSel ? 0.3 : 0.4))
            ctx.addPath(path)
            ctx.setFillColor(isSel ? rgb(0xFFFFFF, 0.98) : rgb(0xE6EDFB, 0.88))
            ctx.fillPath()
            ctx.restoreGState()

            // Title bar band.
            let barH = cardH * 0.24
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(isSel ? rgb(0xFFB02E) : rgb(0x8FA2D6, 0.9))
            ctx.fill(CGRect(x: x, y: rect.maxY - barH, width: cardW, height: barH))
            // Content hint: two faint lines/blocks so cards read as windows.
            ctx.setFillColor(isSel ? rgb(0x2D3FA0, 0.22) : rgb(0x2D3FA0, 0.16))
            ctx.fill(CGRect(x: x + 34, y: y + 38, width: cardW * 0.5, height: 22))
            ctx.fill(CGRect(x: x + 34, y: y + 80, width: cardW * 0.72, height: 22))
            ctx.restoreGState()

            // Title-bar dots.
            if showDots {
                let dotR: CGFloat = 10
                let cy = rect.maxY - barH / 2
                let colors: [CGColor] = isSel
                    ? [rgb(0xFFFFFF, 0.95), rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0.55)]
                    : [rgb(0xFFFFFF, 0.9), rgb(0xFFFFFF, 0.7), rgb(0xFFFFFF, 0.5)]
                for (i, c) in colors.enumerated() {
                    let cx = x + 36 + CGFloat(i) * 30
                    ctx.setFillColor(c)
                    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
                }
            }
        }
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx, pixels: pixels)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <outdir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = out.appendingPathComponent("Vitrin.iconset", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for s in specs {
    try render(pixels: s.px).write(to: iconset.appendingPathComponent("\(s.name).png"))
}
try render(pixels: 1024).write(to: out.appendingPathComponent("Vitrin.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("Vitrin.icns").path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(1) }
print("Wrote \(out.appendingPathComponent("Vitrin.icns").path)")

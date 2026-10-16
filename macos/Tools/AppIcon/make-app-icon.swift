#!/usr/bin/env swift
// Draws the placeholder app icon of LinkLens (the lens of the mockup in a white rounded square) at
// every size macOS asks for, into the AppIcon set of the asset catalogue. Not part of the app.
//
// Run from anywhere (about 2 s):
//
//     swift macos/Tools/AppIcon/make-app-icon.swift
//     swift macos/Tools/AppIcon/make-app-icon.swift --preview /tmp/icon-preview.png
//
// `--preview` also writes one PNG showing the icon at 16, 32, 64, 128 and 256 pt on a light and a
// dark background, to check it without building the app. Only CoreGraphics and ImageIO are used, so
// the result is the same on every Mac.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The icon's colours, from the approved mockup (light mode, the Dock shows one icon only on macOS 15).
enum Colors {
    static let accent = rgb(0x0068D6)
    static let bodyTop = rgb(0xFFFFFF)
    static let bodyBottom = rgb(0xE9ECF1)
    static let border = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10)
    static let shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30)

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Draws the icon in a `pixels` × `pixels` square. Geometry of Apple's macOS grid: on a 1024 canvas
/// the body is 824 wide, 100 from each edge, with a 185 corner radius and a soft shadow under it.
func drawIcon(in context: CGContext, pixels: CGFloat) {
    let unit = pixels / 1024
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)

    // Shadow under the body (CoreGraphics' y axis goes up: a negative offset is below).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 22 * unit, color: Colors.shadow)
    context.addPath(bodyPath)
    context.setFillColor(Colors.bodyTop)
    context.fillPath()
    context.restoreGState()

    // White body with a faint vertical gradient, and a thin border so it stays visible on white.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Colors.bodyTop, Colors.bodyBottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    context.restoreGState()
    context.addPath(bodyPath)
    context.setStrokeColor(Colors.border)
    context.setLineWidth(max(2 * unit, 0.5))
    context.strokePath()

    // The lens, with the proportions of the mockup's 72 pt square: ring of radius 21, dot of 9,
    // four marks from the ring towards the centre, 3 pt lines. Lines never get thinner than 1.4 px
    // so the 16 px icon keeps its ring.
    let scale = body.width / 72
    let center = CGPoint(x: body.midX, y: body.midY)
    let line = max(3 * scale, 1.4)
    context.setStrokeColor(Colors.accent)
    context.setFillColor(Colors.accent)
    context.setLineWidth(line)
    context.setLineCap(.round)

    context.addEllipse(in: CGRect(x: center.x - 21 * scale, y: center.y - 21 * scale, width: 42 * scale, height: 42 * scale))
    context.strokePath()
    context.fillEllipse(in: CGRect(x: center.x - 9 * scale, y: center.y - 9 * scale, width: 18 * scale, height: 18 * scale))

    // Small sizes: the marks would blur into the ring, they are left out below 64 px.
    if pixels >= 64 {
        for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
            context.move(to: CGPoint(x: center.x + dx * 21 * scale, y: center.y + dy * 21 * scale))
            context.addLine(to: CGPoint(x: center.x + dx * 15 * scale, y: center.y + dy * 15 * scale))
        }
        context.strokePath()
    }
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func iconImage(pixels: Int) -> CGImage {
    let context = makeContext(width: pixels, height: pixels)
    context.interpolationQuality = .high
    drawIcon(in: context, pixels: CGFloat(pixels))
    return context.makeImage()!
}

// MARK: - AppIcon set

let scriptURL = URL(fileURLWithPath: #filePath)
let macosFolder = scriptURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let iconSet = macosFolder.appending(path: "LinkLens/Resources/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png" }
}

let slots = [16, 32, 128, 256, 512].flatMap { points in [Slot(points: points, scale: 1), Slot(points: points, scale: 2)] }
for slot in slots {
    try writePNG(iconImage(pixels: slot.pixels), to: iconSet.appending(path: slot.filename))
}

let images = slots.map { slot -> [String: String] in
    ["filename": slot.filename, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"]
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appending(path: "Contents.json"))
print("AppIcon: \(slots.count) PNG in \(iconSet.path)")

// MARK: - Preview

if let index = CommandLine.arguments.firstIndex(of: "--preview"), index + 1 < CommandLine.arguments.count {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    // At 2x, like a Retina screen: 16 pt = 32 px.
    let sizes = [16, 32, 64, 128, 256].map { $0 * 2 }
    let gap = 40
    let width = sizes.reduce(gap) { $0 + $1 + gap }
    let rowHeight = sizes.max()! + 2 * gap
    let context = makeContext(width: width, height: rowHeight * 2)
    for (row, background) in [Colors.rgb(0x141416), Colors.rgb(0xECECF0)].enumerated() {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: row * rowHeight, width: width, height: rowHeight))
        var x = gap
        for size in sizes {
            let y = row * rowHeight + (rowHeight - size) / 2
            context.draw(iconImage(pixels: size), in: CGRect(x: x, y: y, width: size, height: size))
            x += size + gap
        }
    }
    try writePNG(context.makeImage()!, to: output)
    print("Preview: \(output.path)")
}

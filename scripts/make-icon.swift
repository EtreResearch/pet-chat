// Draws the Pet Chat app icon (the blue cat from PetCharacterView on a cream tile)
// and writes the macOS AppIcon.appiconset PNGs + Contents.json.
// Usage: swift scripts/make-icon.swift PetChat/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let cream = rgb(0xFB / 255, 0xF8 / 255, 0xF1 / 255)
let blue = rgb(0.38, 0.46, 0.61)
let dark = rgb(0.19, 0.24, 0.34)

/// The static (awake, not thinking) cat from PetCharacterView, in its 64×64 y-down space.
func drawCat(_ ctx: CGContext) {
    func ellipse(_ rect: CGRect, _ color: CGColor) { ctx.setFillColor(color); ctx.fillEllipse(in: rect) }
    ctx.setStrokeColor(blue); ctx.setLineWidth(7); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 43, y: 57))
    ctx.addCurve(to: CGPoint(x: 57, y: 38), control1: CGPoint(x: 65, y: 64), control2: CGPoint(x: 61, y: 45))
    ctx.strokePath()
    ellipse(CGRect(x: 16, y: 29, width: 34, height: 34), blue)
    ctx.setFillColor(blue)
    ctx.addLines(between: [CGPoint(x: 13, y: 23), CGPoint(x: 13, y: 2), CGPoint(x: 27, y: 14),
                           CGPoint(x: 39, y: 14), CGPoint(x: 51, y: 2), CGPoint(x: 51, y: 24)])
    ctx.closePath(); ctx.fillPath()
    ellipse(CGRect(x: 11, y: 11, width: 42, height: 31), blue)
    ellipse(CGRect(x: 24, y: 39, width: 18, height: 21), rgb(1, 1, 1, 0.13))
    ellipse(CGRect(x: 16, y: 57, width: 17, height: 7), blue)
    ellipse(CGRect(x: 34, y: 57, width: 17, height: 7), blue)
    for x in [23.0, 41.0] {
        ellipse(CGRect(x: x - 2, y: 22, width: 4, height: 6), dark)
        ellipse(CGRect(x: x - 1, y: 23, width: 1.2, height: 1.5), rgb(1, 1, 1))
    }
    ellipse(CGRect(x: 30, y: 29, width: 4, height: 3), dark)
}

/// Renders the icon at `pixels`×`pixels`, laid out on a 1024 design grid.
func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixels) / 1024
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: k, y: k)
    // Tile: 824×824 centred, corner radius 185, soft shadow (shadow params are in device pixels).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: rgb(0, 0, 0, 0.25))
    ctx.setFillColor(cream)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    // Cat: flip to y-down, scale its ~54×62 bounds (x 11…65, y 2…64) to ~600 tall, centre in the tile.
    let catScale: CGFloat = 600 / 62
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: catScale, y: -catScale)
    ctx.translateBy(x: -38, y: -33)
    drawCat(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(render(pixels: points * scale), to: outputDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons + Contents.json to \(outputDir.path)")

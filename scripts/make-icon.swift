// Derives the macOS AppIcon.appiconset sizes from its 1024×1024 master PNG.
// Usage: swift scripts/make-icon.swift PetChat/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics
import ImageIO

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let masterURL = outputDir.appendingPathComponent("icon_512x512@2x.png")
guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Missing or unreadable 1024×1024 master: \(masterURL.path)\n", stderr)
    exit(1)
}
guard master.width == 1024, master.height == 1024 else {
    fputs("Master must be 1024×1024; found \(master.width)×\(master.height)\n", stderr)
    exit(1)
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    try representation.representation(using: .png, properties: [:])!.write(to: url)
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        if points * scale != 1024 {
            try writePNG(render(pixels: points * scale), to: outputDir.appendingPathComponent(name))
        }
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))
print("Wrote 9 derived icons + Contents.json from \(masterURL.path)")

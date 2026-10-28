// Converts a generated icon render into a proper macOS AppIcon.png:
// crops the tile, applies a rounded-rect mask on a transparent canvas,
// and scales it to Apple's 824/1024 icon grid.
// Usage: swift scripts/make_icon.swift <input> <output> <cropX> <cropY> <cropSize>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 6,
      let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let cx = Double(args[3]), let cy = Double(args[4]), let cs = Double(args[5]) else {
    print("Usage: make_icon.swift <input> <output> <cropX> <cropY> <cropSize>")
    exit(1)
}

guard let cropped = cg.cropping(to: CGRect(x: cx, y: cy, width: cs, height: cs)) else {
    print("Crop failed"); exit(1)
}

let canvas = 1024
let tile: CGFloat = 824
let origin = (CGFloat(canvas) - tile) / 2
let radius = tile * 0.2237

let ctx = CGContext(
    data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let rect = CGRect(x: origin, y: origin, width: tile, height: tile)
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.draw(cropped, in: rect)

let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")

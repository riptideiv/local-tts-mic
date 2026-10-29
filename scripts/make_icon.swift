import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        NSColor(calibratedRed: 0.30, green: 0.30, blue: 0.74, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 464, height: 464), xRadius: 108, yRadius: 108).fill()
        NSColor.white.setFill()
        for (i, height) in [90.0, 180, 274, 340, 224, 144, 70].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 116 + Double(i) * 42, y: 256 - height / 2, width: 27, height: height), xRadius: 13.5, yRadius: 13.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

import AppKit

// Original, code-generated artwork; no external images or fonts are required.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                     ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let shape = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944),
                            xRadius: 220, yRadius: 220)
    NSGradient(starting: NSColor(calibratedWhite: 0.18, alpha: 1),
               ending: NSColor(calibratedWhite: 0.055, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor(calibratedWhite: 1, alpha: 0.13).setStroke()
    shape.lineWidth = 5; shape.stroke()
    NSColor(calibratedRed: 1, green: 0.28, blue: 0.42, alpha: 0.15).setFill()
    NSBezierPath(ovalIn: NSRect(x: 152, y: 396, width: 232, height: 232)).fill()
    NSColor(calibratedRed: 1, green: 0.28, blue: 0.42, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 198, y: 442, width: 140, height: 140)).fill()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    for (index, height) in [156.0, 270, 424, 324, 218, 132].enumerated() {
        let rect = NSRect(x: 426 + Double(index) * 66, y: 512 - height / 2, width: 36, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}

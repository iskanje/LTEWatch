import AppKit

// Render the same SF Symbol used by the menu bar into the macOS icon sizes.
// Usage: swift Tools/generate-icon.swift work/AppIcon.iconset
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let configuration = NSImage.SymbolConfiguration(pointSize: 540, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) else {
    fatalError("The antenna SF Symbol is unavailable.")
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(srgbRed: 0.0, green: 0.56, blue: 0.63, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 186, yRadius: 186).fill()
        let factor = min(600 / symbol.size.width, 600 / symbol.size.height)
        let size = NSSize(width: symbol.size.width * factor, height: symbol.size.height * factor)
        symbol.draw(in: NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon.") }
        try png.write(to: output.appendingPathComponent(name))
    }
}

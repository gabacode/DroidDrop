// Renders the 1024px app icon: usage `swift make-icon.swift out.png`
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background tile, inset per the macOS icon grid.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(
    starting: NSColor(red: 0.30, green: 0.88, blue: 0.56, alpha: 1),
    ending: NSColor(red: 0.07, green: 0.58, blue: 0.36, alpha: 1)
)!.draw(in: tilePath, angle: -90)

// Phone body.
let phone = NSRect(x: 352, y: 210, width: 320, height: 604)
NSColor.white.setFill()
NSBezierPath(roundedRect: phone, xRadius: 58, yRadius: 58).fill()
let screen = phone.insetBy(dx: 26, dy: 26)
NSGradient(
    starting: NSColor(red: 0.13, green: 0.70, blue: 0.44, alpha: 1),
    ending: NSColor(red: 0.05, green: 0.45, blue: 0.29, alpha: 1)
)!.draw(in: NSBezierPath(roundedRect: screen, xRadius: 36, yRadius: 36), angle: -90)

// Download arrow on the screen.
let config = NSImage.SymbolConfiguration(pointSize: 220, weight: .heavy)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let arrowSize = arrow.size
    arrow.draw(in: NSRect(
        x: screen.midX - arrowSize.width / 2, y: screen.midY - arrowSize.height / 2,
        width: arrowSize.width, height: arrowSize.height
    ))
}

NSGraphicsContext.current = nil
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: output)

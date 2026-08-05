import AppKit
import Foundation

// Usage: swift compose_shots.swift <input.png> <output.png> <headline> <subline>
// Renders a 1284x2778 App Store screenshot: brand-indigo gradient background,
// white headline + subline, device-framed capture bleeding off the bottom.

let canvasW = 1284, canvasH = 2778
let args = CommandLine.arguments
guard args.count == 5, let source = NSImage(contentsOfFile: args[1]) else {
    fatalError("usage: compose_shots.swift <in> <out> <headline> <subline>")
}
let (outPath, headline, subline) = (args[2], args[3], args[4])

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvasW, pixelsHigh: canvasH,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: canvasW, height: canvasH)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Brand gradient: Minute's accent indigo, darker at the bottom for depth.
let top = NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.97, alpha: 1)
let bottom = NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.62, alpha: 1)
NSGradient(starting: top, ending: bottom)!
    .draw(in: NSRect(x: 0, y: 0, width: canvasW, height: canvasH), angle: -90)

// Headline + subline live in the top band (AppKit origin is bottom-left).
func draw(_ text: String, font: NSFont, color: NSColor, centerY: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
    ])
    let box = attributed.boundingRect(
        with: NSSize(width: canvasW - 120, height: 600), options: .usesLineFragmentOrigin
    )
    attributed.draw(with: NSRect(
        x: 60, y: centerY - box.height / 2, width: CGFloat(canvasW) - 120, height: box.height
    ), options: .usesLineFragmentOrigin)
}
draw(headline, font: NSFont.systemFont(ofSize: 92, weight: .bold),
     color: .white, centerY: CGFloat(canvasH) - 190)
draw(subline, font: NSFont.systemFont(ofSize: 44, weight: .medium),
     color: NSColor.white.withAlphaComponent(0.82), centerY: CGFloat(canvasH) - 340)

// Device-framed screenshot: rounded capture inside a near-black bezel,
// soft shadow, bleeding slightly off the bottom edge.
let shotW: CGFloat = 1040
let scale = shotW / source.size.width
let shotH = source.size.height * scale
let bezel: CGFloat = 18
let frameRect = NSRect(
    x: (CGFloat(canvasW) - shotW) / 2 - bezel,
    y: CGFloat(canvasH) - 470 - shotH - bezel, // top of frame sits 470pt down
    width: shotW + bezel * 2, height: shotH + bezel * 2
)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 60
shadow.shadowOffset = NSSize(width: 0, height: -24)
NSGraphicsContext.current?.saveGraphicsState()
shadow.set()
NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
NSBezierPath(roundedRect: frameRect, xRadius: 130, yRadius: 130).fill()
NSGraphicsContext.current?.restoreGraphicsState()

let shotRect = frameRect.insetBy(dx: bezel, dy: bezel)
NSGraphicsContext.current?.saveGraphicsState()
NSBezierPath(roundedRect: shotRect, xRadius: 112, yRadius: 112).addClip()
source.draw(in: shotRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

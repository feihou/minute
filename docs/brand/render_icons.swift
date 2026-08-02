// Renders Minute app icons (light / dark / tinted) at 1024x1024 per the brand proposal:
// waveform capsule mark + "minute" SF Rounded wordmark with blue i-dot.
import AppKit

let S: CGFloat = 1024

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

struct Bar {
    let slot: CGFloat      // -3...3 relative to center
    let height: CGFloat    // px
    let color: NSColor
}

enum Mode: String { case light, dark, tinted }

let barW: CGFloat = 68
let gap: CGFloat = 34
let markCY: CGFloat = S - 400   // bottom-left coords; mark centered 400px from top

func bars(for mode: Mode) -> [Bar] {
    // heights: small, mid, tall, tallest, tall, mid, small
    let hs: [CGFloat] = [150, 240, 330, 420, 330, 240, 150]
    let lightColors: [NSColor] = [
        hex(0xC9D9FB), hex(0xA5BFF9), hex(0x7D9DF6), hex(0x4A5CEC),
        hex(0x7D9DF6), hex(0xA5BFF9), hex(0xC9D9FB),
    ]
    let darkColors: [NSColor] = [
        hex(0x93A9E0, 0.55), hex(0x8FA8F0, 0.75), hex(0x86A3FA), hex(0x6D7FFF),
        hex(0x86A3FA), hex(0x8FA8F0, 0.75), hex(0x93A9E0, 0.55),
    ]
    let tintAlphas: [CGFloat] = [0.35, 0.55, 0.78, 1.0, 0.78, 0.55, 0.35]
    return (0..<7).map { i in
        let color: NSColor
        switch mode {
        case .light: color = lightColors[i]
        case .dark: color = darkColors[i]
        case .tinted: color = NSColor(white: 1, alpha: tintAlphas[i])
        }
        return Bar(slot: CGFloat(i - 3), height: hs[i], color: color)
    }
}

func capsule(x: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, color: NSColor) {
    let rect = NSRect(x: x - w / 2, y: cy - h / 2, width: w, height: h)
    let path = NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2)
    color.setFill()
    path.fill()
}

func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let desc = base.fontDescriptor.withDesign(.rounded),
          let font = NSFont(descriptor: desc, size: size) else { return base }
    return font
}

func drawWordmark(mode: Mode, includeText: Bool) {
    guard includeText else { return }
    let fontSize: CGFloat = 168
    let font = roundedFont(size: fontSize, weight: .semibold)
    let textColor: NSColor = mode == .light ? hex(0x171A2E) : .white
    let dotColor: NSColor = mode == .light ? hex(0x4A5CEC) : hex(0x8FA8F0)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: -1.5]
    // dotless i (U+0131); we draw the brand-blue dot ourselves
    let text = "m\u{0131}nute" as NSString
    let size = text.size(withAttributes: attrs)
    let originX = (S - size.width) / 2
    let baselineY: CGFloat = 118
    text.draw(at: NSPoint(x: originX, y: baselineY), withAttributes: attrs)
    // place the dot centered over the dotless i
    let mWidth = ("m" as NSString).size(withAttributes: attrs).width
    let iWidth = ("\u{0131}" as NSString).size(withAttributes: attrs).width
    let dotR: CGFloat = fontSize * 0.075
    let dotCX = originX + mWidth + iWidth / 2
    let xHeightTop = baselineY - font.descender + font.xHeight
    let dotCY = xHeightTop + fontSize * 0.115
    let dotRect = NSRect(x: dotCX - dotR, y: dotCY - dotR, width: dotR * 2, height: dotR * 2)
    dotColor.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
}

// draw into an explicit 1px-per-point bitmap so output is exactly `canvas` pixels
// (lockFocus renders at the display's 2x backing scale, which actool rejects)
func makeRep(_ w: CGFloat, _ h: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    return rep
}

func render(mode: Mode, includeText: Bool, canvas: CGFloat = S) -> NSBitmapImageRep {
    let rep = makeRep(canvas, canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if mode == .light {
        // subtle vertical wash so the light icon isn't dead flat
        let grad = NSGradient(starting: hex(0xF2F6FE), ending: .white)!
        grad.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: 90)
    }
    let cy = includeText ? markCY : canvas / 2
    // soft echo capsules behind the mid bars for the layered look
    let echoColor: NSColor
    switch mode {
    case .light: echoColor = hex(0x6E86F2, 0.13)
    case .dark: echoColor = hex(0x86A3FA, 0.12)
    case .tinted: echoColor = NSColor(white: 1, alpha: 0.10)
    }
    for slot: CGFloat in [-2, -1, 1, 2] {
        let x = canvas / 2 + slot * (barW + gap)
        let h: CGFloat = slot.magnitude == 1 ? 290 : 190
        capsule(x: x, cy: cy, w: barW * 1.6, h: h, color: echoColor)
    }
    for bar in bars(for: mode) {
        let x = canvas / 2 + bar.slot * (barW + gap)
        capsule(x: x, cy: cy, w: barW, h: bar.height, color: bar.color)
    }
    drawWordmark(mode: mode, includeText: includeText)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png \(path)") }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for mode: Mode in [.light, .dark, .tinted] {
    writePNG(render(mode: mode, includeText: true), to: "\(outDir)/AppIcon-\(mode.rawValue.capitalized).png")
}

// preview sheet: light as-is, dark and tinted composited on iOS-style dark backgrounds
let previewRep = makeRep(S * 3 + 80, S)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: previewRep)
hex(0x808080).setFill()
NSRect(x: 0, y: 0, width: S * 3 + 80, height: S).fill()
let darkBG = NSGradient(starting: hex(0x30313A), ending: hex(0x121218))!
darkBG.draw(in: NSRect(x: S + 40, y: 0, width: S, height: S), angle: 90)
darkBG.draw(in: NSRect(x: 2 * S + 80, y: 0, width: S, height: S), angle: 90)
for (i, mode) in [Mode.light, .dark, .tinted].enumerated() {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.addRepresentation(render(mode: mode, includeText: true))
    img.draw(at: NSPoint(x: CGFloat(i) * (S + 40), y: 0), from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()
writePNG(previewRep, to: "\(outDir)/preview.png")

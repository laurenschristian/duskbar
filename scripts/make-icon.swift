import AppKit

// Renders icon.png (512px) and Resources/AppIcon.icns on the macOS icon grid. Run: swift scripts/make-icon.swift
let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // Apple grid: 824pt tile, 100pt margin, continuous corners, soft drop shadow.
    let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x1B1640).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let horizon: CGFloat = 400
    NSGradient(colors: [color(0x2A1F5C), color(0x7A3B7E), color(0xE0605A), color(0xFFB36B)],
               atLocations: [0, 0.4, 0.75, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 100, y: horizon, width: 824, height: 524), angle: -90)

    let center = NSPoint(x: 512, y: horizon)
    NSGradient(colors: [color(0xFFD27A, 0.55), color(0xFFD27A, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 360, options: [])
    let sun = NSBezierPath(ovalIn: NSRect(x: 512 - 190, y: horizon - 190, width: 380, height: 380))
    NSGradient(colors: [color(0xFFF1B8), color(0xFFB14A)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: sun, angle: -90)

    NSGradient(colors: [color(0x241B4F), color(0x120E2B)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: horizon - 100), angle: -90)
    for (i, w) in [300.0, 220, 150, 90].enumerated() {
        color(0xFFB14A, 0.55 - Double(i) * 0.1).setFill()
        let y = horizon - 42 - CGFloat(i) * 52
        NSBezierPath(roundedRect: NSRect(x: 512 - w / 2, y: y, width: w, height: 14), xRadius: 7, yRadius: 7).fill()
    }

    // Top edge highlight, like Apple's glass rim.
    NSGradient(colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 100, y: 824, width: 824, height: 100), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFFFFF, 0.12).setStroke()
    let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1, dy: 1), xRadius: 184, yRadius: 184)
    rim.lineWidth = 2
    rim.stroke()
    return true
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func run(_ path: String, _ args: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    try task.run()
    task.waitUntilExit()
}

// pngquant (brew install pngquant) shrinks each PNG about 70% with no visible loss.
let pngquant = ["/opt/homebrew/bin/pngquant", "/usr/local/bin/pngquant"].first { FileManager.default.isExecutableFile(atPath: $0) }
func write(_ data: Data, _ url: URL) throws {
    try data.write(to: url)
    if let pngquant { try run(pngquant, ["--force", "--skip-if-larger", "--quality=80-95", "--output", url.path, url.path]) }
}

// Writes the icns container directly so the quantized PNG bytes are kept; iconutil re-encodes them larger.
let entries: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
                                ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512)]
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duskbar-icon.png")
var body = Data()
for (type, px) in entries {
    try write(png(px), tmp)
    let data = try Data(contentsOf: tmp)
    body.append(type.data(using: .ascii)!)
    body.append(withUnsafeBytes(of: UInt32(data.count + 8).bigEndian) { Data($0) })
    body.append(data)
}
var icns = "icns".data(using: .ascii)!
icns.append(withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { Data($0) })
icns.append(body)
try FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try icns.write(to: URL(fileURLWithPath: "Resources/AppIcon.icns"))
try write(png(512), URL(fileURLWithPath: "icon.png"))

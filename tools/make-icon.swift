// Génère l'icône de l'app : swift tools/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments[1]
let iconset = NSTemporaryDirectory() + "Dictee.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// Couleurs de la marque : corail -> violet
let coral = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
let violet = NSColor(srgbRed: 0.46, green: 0.33, blue: 1.00, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Carré arrondi façon macOS (marge de 10 % comme la grille officielle)
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [coral, violet])!.draw(in: shape, angle: -65)

    // Ondes discrètes de part et d'autre du micro
    NSColor.white.withAlphaComponent(0.35).setFill()
    for (i, h) in [0.16, 0.26, 0.16].enumerated() {
        for side in [-1.0, 1.0] {
            let x = s / 2 + CGFloat(side) * s * (0.2 + 0.065 * Double(i)) - s * 0.0175
            let bar = NSRect(x: x, y: s / 2 - s * h / 2, width: s * 0.035, height: s * h)
            NSBezierPath(roundedRect: bar, xRadius: s * 0.0175, yRadius: s * 0.0175).fill()
        }
    }

    // Micro blanc au centre
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.34, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = mic.size
        mic.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).write(to: URL(fileURLWithPath: iconset).appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", output]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Icône créée : \(output)" : "Échec iconutil")

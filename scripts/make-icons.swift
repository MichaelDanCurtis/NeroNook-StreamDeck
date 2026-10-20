import AppKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, base) in [("plugin", 72), ("action", 28), ("key", 72), ("stop", 28), ("stopkey", 72)] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus()
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        let unit = CGFloat(size) / 72
        NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.71, alpha: 1).setStroke()
        let path = NSBezierPath(); path.lineWidth = 5 * unit; path.lineCapStyle = .round
        if name.hasPrefix("stop") {
            NSColor.systemRed.setFill(); NSBezierPath(roundedRect: .init(x: 23*unit, y: 23*unit, width: 26*unit, height: 26*unit), xRadius: 4*unit, yRadius: 4*unit).fill()
        } else {
            path.move(to: NSPoint(x: 22*unit, y: 22*unit)); path.line(to: NSPoint(x: 22*unit, y: 50*unit)); path.line(to: NSPoint(x: 50*unit, y: 22*unit)); path.line(to: NSPoint(x: 50*unit, y: 50*unit)); path.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + (scale == 2 ? "@2x" : "") + ".png"))
    }
}

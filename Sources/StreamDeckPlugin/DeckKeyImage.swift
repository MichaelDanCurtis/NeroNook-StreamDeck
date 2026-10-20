import AppKit
import NookPluginSDK

/// Original vector artwork rendered locally. Titles use Elgato's documented
/// overlay; the ring counts completed workflow steps only when supplied.
enum DeckKeyImage {
    static func data(stop: Bool, phase: PluginRunPhase?, review: Bool, progress: Double?, frame: Int) -> String {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(rect: .init(x: 0, y: 0, width: 144, height: 144)).fill()
        let color: NSColor = review || phase == .cancelling ? .systemOrange : phase == .succeeded ? .systemMint : phase == .failed ? .systemRed : phase == .interrupted ? .systemPurple : stop ? .systemRed : .systemCyan
        let ring = NSBezierPath(ovalIn: .init(x: 46, y: 90, width: 52, height: 52)); ring.lineWidth = 3
        color.withAlphaComponent(0.2).setStroke(); ring.stroke()
        let arc = NSBezierPath(); arc.lineWidth = 3; arc.lineCapStyle = .round
        if let progress { arc.appendArc(withCenter: .init(x: 72, y: 116), radius: 26, startAngle: 90, endAngle: 90 - CGFloat(min(1, max(0, progress))) * 360, clockwise: true) }
        else if phase == .running || phase == .cancelling { arc.appendArc(withCenter: .init(x: 72, y: 116), radius: 26, startAngle: CGFloat(frame % 12) * 30, endAngle: CGFloat(frame % 12) * 30 + 90) }
        color.setStroke(); arc.stroke(); color.setFill()
        if phase == .succeeded {
            let p = NSBezierPath(); p.lineWidth = 4; p.lineCapStyle = .round; p.move(to: .init(x: 61, y: 116)); p.line(to: .init(x: 69, y: 108)); p.line(to: .init(x: 84, y: 126)); p.stroke()
        } else if stop || phase == .cancelled { NSBezierPath(roundedRect: .init(x: 63, y: 107, width: 18, height: 18), xRadius: 3, yRadius: 3).fill() }
        else if review {
            NSBezierPath(rect: .init(x: 64, y: 107, width: 5, height: 19)).fill(); NSBezierPath(rect: .init(x: 75, y: 107, width: 5, height: 19)).fill()
        } else if phase == .failed || phase == .interrupted {
            let p = NSBezierPath(); p.lineWidth = 4; p.move(to: .init(x: 72, y: 114)); p.line(to: .init(x: 72, y: 126)); p.stroke(); NSBezierPath(ovalIn: .init(x: 70, y: 106, width: 4, height: 4)).fill()
        } else {
            let p = NSBezierPath(); p.move(to: .init(x: 66, y: 105)); p.line(to: .init(x: 84, y: 116)); p.line(to: .init(x: 66, y: 127)); p.close(); p.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return "data:image/png;base64," + bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }
}

import AppKit

/// Branchyard's logo, drawn in code so it stays sharp at every size:
/// a rounded green tile with a white trunk and an amber branch growing off it.
public enum AppIconArt {
    public static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    /// PNG data at an exact pixel size (for building the .icns).
    public static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws in a 1024-point design space scaled to `rect`.
    public static func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 1024, y: rect.height / 1024)

        // Tile (macOS icon grid: 824pt body, 100pt margin) with a soft drop shadow.
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(srgbRed: 0.05, green: 0.40, blue: 0.36, alpha: 1).setFill()
        tilePath.fill()
        ctx.restoreGState()

        NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1),   // emerald
            NSColor(srgbRed: 0.03, green: 0.45, blue: 0.50, alpha: 1),   // deep teal
        ])?.draw(in: tilePath, angle: -60)

        // Subtle top highlight.
        ctx.saveGState()
        tilePath.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])?
            .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
        ctx.restoreGState()

        let white = NSColor.white
        let amber = NSColor(srgbRed: 0.99, green: 0.76, blue: 0.20, alpha: 1)
        let line: CGFloat = 58

        // Branch: curves off the trunk to the right.
        let branch = NSBezierPath()
        branch.move(to: NSPoint(x: 400, y: 380))
        branch.curve(to: NSPoint(x: 640, y: 610),
                     controlPoint1: NSPoint(x: 400, y: 540),
                     controlPoint2: NSPoint(x: 640, y: 450))
        branch.lineWidth = line
        branch.lineCapStyle = .round
        amber.setStroke()
        branch.stroke()

        // Trunk.
        let trunk = NSBezierPath()
        trunk.move(to: NSPoint(x: 400, y: 280))
        trunk.line(to: NSPoint(x: 400, y: 744))
        trunk.lineWidth = line
        trunk.lineCapStyle = .round
        white.setStroke()
        trunk.stroke()

        // Commit nodes: ring + filled center.
        func node(_ center: NSPoint, ring: NSColor) {
            let outer = NSBezierPath(ovalIn: NSRect(x: center.x - 84, y: center.y - 84, width: 168, height: 168))
            ring.setFill()
            outer.fill()
            let inner = NSBezierPath(ovalIn: NSRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88))
            NSColor(srgbRed: 0.04, green: 0.42, blue: 0.42, alpha: 1).setFill()
            inner.fill()
        }
        node(NSPoint(x: 400, y: 280), ring: white)
        node(NSPoint(x: 400, y: 744), ring: white)
        node(NSPoint(x: 640, y: 650), ring: amber)

        ctx.restoreGState()
    }
}

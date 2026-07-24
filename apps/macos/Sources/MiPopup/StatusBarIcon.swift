import AppKit

enum StatusBarIcon {
    static func make() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
           let bundledImage = NSImage(contentsOf: url) {
            return prepare(bundledImage)
        }

        return drawVectorFallback()
    }

    private static func prepare(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "MiPopup"
        return image
    }

    private static func drawVectorFallback() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let capsule = NSBezierPath(
                roundedRect: NSRect(x: 1.75, y: 5.25, width: 14.5, height: 7.5),
                xRadius: 3.75,
                yRadius: 3.75
            )
            capsule.lineWidth = 1.5
            capsule.stroke()

            let dot = NSBezierPath(
                ovalIn: NSRect(x: 4.1, y: 7.35, width: 3.3, height: 3.3)
            )
            dot.fill()

            let upperWave = NSBezierPath()
            upperWave.move(to: NSPoint(x: 6.25, y: 14.25))
            upperWave.curve(
                to: NSPoint(x: 11.75, y: 14.25),
                controlPoint1: NSPoint(x: 8.0, y: 15.25),
                controlPoint2: NSPoint(x: 10.0, y: 15.25)
            )
            upperWave.lineWidth = 1.4
            upperWave.lineCapStyle = .round
            upperWave.stroke()

            let lowerWave = NSBezierPath()
            lowerWave.move(to: NSPoint(x: 6.25, y: 3.75))
            lowerWave.curve(
                to: NSPoint(x: 11.75, y: 3.75),
                controlPoint1: NSPoint(x: 8.0, y: 2.75),
                controlPoint2: NSPoint(x: 10.0, y: 2.75)
            )
            lowerWave.lineWidth = 1.4
            lowerWave.lineCapStyle = .round
            lowerWave.stroke()

            return true
        }
        return prepare(image)
    }
}

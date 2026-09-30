import SwiftUI

/// Shared by the SwiftUI clip and the AppKit backing layer.
struct IslandOutline: Shape {
    var cornerRadius: CGFloat
    var joinRightEdge = false
    var continuousCorners = true

    func path(in rect: CGRect) -> Path {
        if continuousCorners {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: joinRightEdge ? 0 : cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            ).path(in: rect)
        }

        // A concave shoulder meets the screen edge, unlike an inward rounded corner.
        let shoulder = min(4, rect.height / 4, rect.width / 4)
        let left = rect.minX + shoulder
        let right = rect.maxX - (joinRightEdge ? 0 : shoulder)
        let radius = min(max(0, cornerRadius), (right - left) / 2, rect.height - shoulder)
        let k: CGFloat = 0.5522847498
        let top = rect.minY
        let bottom = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        if !joinRightEdge {
            path.addCurve(
                to: CGPoint(x: right, y: top + shoulder),
                control1: CGPoint(x: rect.maxX - shoulder * k, y: top),
                control2: CGPoint(x: right, y: top + shoulder * (1 - k))
            )
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addCurve(
                to: CGPoint(x: right - radius, y: bottom),
                control1: CGPoint(x: right, y: bottom - radius * (1 - k)),
                control2: CGPoint(x: right - radius * (1 - k), y: bottom)
            )
        } else {
            path.addLine(to: CGPoint(x: right, y: bottom))
        }
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: left, y: bottom - radius),
            control1: CGPoint(x: left + radius * (1 - k), y: bottom),
            control2: CGPoint(x: left, y: bottom - radius * (1 - k))
        )
        path.addLine(to: CGPoint(x: left, y: top + shoulder))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: top),
            control1: CGPoint(x: left, y: top + shoulder * (1 - k)),
            control2: CGPoint(x: rect.minX + shoulder * k, y: top)
        )
        path.closeSubpath()
        return path
    }
}

import SwiftUI

/// The Dynamic Island silhouette: flush square top edge, rounded bottom, and
/// inverted (concave) top corners that flare the panel out into the menu bar.
/// The concave corners are drawn inside `rect`, so the opaque body is inset by
/// `topRadius` on each side and only the very top edge spans the full width.
struct NotchShape: Shape {
    var topRadius: CGFloat = NotchGeometry.wing
    var bottomRadius: CGFloat = 22

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 2))
        let bottom = max(0, min(bottomRadius, min(rect.width / 2 - top, rect.height - top)))

        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left inverted corner, curving down into the body.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right inverted corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

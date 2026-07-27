import CoreGraphics
import SwiftUI

/// Minimal SVG path-data parser, so provider logos can use the same path strings
/// the T3 Code web app ships instead of hand-approximated shapes.
/// SVG and SwiftUI both use a y-down coordinate space, so no flip is needed.
enum SVGPath {
    static func path(from data: String, viewBox: CGSize, fitting rect: CGRect) -> Path {
        let raw = parse(data)
        guard viewBox.width > 0, viewBox.height > 0, !rect.isEmpty else { return raw }

        // preserveAspectRatio="xMidYMid meet"
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.minX + (rect.width - viewBox.width * scale) / 2
        let dy = rect.minY + (rect.height - viewBox.height * scale) / 2

        var transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        return Path(raw.cgPath.copy(using: &transform) ?? raw.cgPath)
    }

    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = Scanner(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        while true {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            if let letter = scanner.peekCommand() {
                command = letter
                scanner.advance()
            } else if command == nil {
                break
            } else if command == "M" {
                command = "L"
            } else if command == "m" {
                command = "l"
            }

            guard let cmd = command else { break }
            let relative = cmd.isLowercase

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(cmd.uppercased()) {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                lastControl = nil
                lastQuadControl = nil

            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil

            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil

            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
                lastQuadControl = nil

            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c1 = point(x1, y1)
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
                lastQuadControl = nil

            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c1 = lastControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
                lastQuadControl = nil

            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
                lastControl = nil

            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
                lastControl = nil

            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number()
                else { return path }
                let end = point(x, y)
                appendArc(
                    to: &path,
                    from: current,
                    to: end,
                    rx: rx,
                    ry: ry,
                    rotationDegrees: rotation,
                    largeArc: largeArc,
                    sweep: sweep
                )
                current = end
                lastControl = nil
                lastQuadControl = nil

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
                lastQuadControl = nil

            default:
                return path
            }
        }

        return path
    }

    /// Endpoint parameterization -> center parameterization -> cubic segments.
    private static func appendArc(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if start == end { return }
        var rx = abs(rx)
        var ry = abs(ry)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2
        let dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale radii up if they cannot span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = max(
            0,
            rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        )
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len != 0 else { return 0 }
            var value = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaAngle = angle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep, deltaAngle > 0 { deltaAngle -= 2 * .pi }
        if sweep, deltaAngle < 0 { deltaAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(deltaAngle) / (.pi / 2))))
        let delta = deltaAngle / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let cosTheta1 = cos(theta)
            let sinTheta1 = sin(theta)
            let theta2 = theta + delta
            let cosTheta2 = cos(theta2)
            let sinTheta2 = sin(theta2)

            func map(_ cosT: CGFloat, _ sinT: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + rx * cosT * cosPhi - ry * sinT * sinPhi,
                    y: cy + rx * cosT * sinPhi + ry * sinT * cosPhi
                )
            }

            let p1 = map(cosTheta1, sinTheta1)
            let p2 = map(cosTheta2, sinTheta2)

            let d1 = CGPoint(
                x: -rx * sinTheta1 * cosPhi - ry * cosTheta1 * sinPhi,
                y: -rx * sinTheta1 * sinPhi + ry * cosTheta1 * cosPhi
            )
            let d2 = CGPoint(
                x: -rx * sinTheta2 * cosPhi - ry * cosTheta2 * sinPhi,
                y: -rx * sinTheta2 * sinPhi + ry * cosTheta2 * cosPhi
            )

            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y),
                control2: CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y)
            )
            theta = theta2
        }
    }

    /// Hand-rolled scanner because SVG path data allows omitted separators,
    /// leading-dot numbers, and sign characters acting as delimiters.
    private struct Scanner {
        private let chars: [Character]
        private var index: Int

        init(_ string: String) {
            chars = Array(string)
            index = 0
        }

        var isAtEnd: Bool { index >= chars.count }

        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while index < chars.count {
                let c = chars[index]
                if c == "," || c.isWhitespace { index += 1 } else { break }
            }
        }

        func peekCommand() -> Character? {
            guard index < chars.count else { return nil }
            let c = chars[index]
            return "MmLlHhVvCcSsQqTtAaZz".contains(c) ? c : nil
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            guard c == "0" || c == "1" else { return nil }
            index += 1
            return c == "1"
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }

            var start = index
            if chars[index] == "+" || chars[index] == "-" { index += 1 }

            var sawDigit = false
            var sawDot = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    sawDigit = true
                    index += 1
                } else if c == ".", !sawDot {
                    sawDot = true
                    index += 1
                } else if (c == "e" || c == "E"), sawDigit {
                    index += 1
                    if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                        index += 1
                    }
                } else {
                    break
                }
            }

            guard sawDigit else {
                index = start
                return nil
            }
            if chars[start] == "+" { start += 1 }
            return CGFloat(Double(String(chars[start..<index])) ?? 0)
        }
    }
}

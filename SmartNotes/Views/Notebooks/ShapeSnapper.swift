import PencilKit
import UIKit

/// Converts a freehand stroke into a clean geometric shape (line, rectangle,
/// triangle, or ellipse) — used for GoodNotes-style "draw and hold" snapping.
enum ShapeSnapper {

    static func snappedStroke(from stroke: PKStroke) -> PKStroke? {
        let sampled = Array(stroke.path.interpolatedPoints(by: .distance(6)))
        let points = sampled.map(\.location)
        guard points.count >= 8 else { return nil }

        let perimeter = pathLength(points)
        guard perimeter > 40 else { return nil }

        let averageWidth = max(sampled.map(\.size.width).reduce(0, +) / CGFloat(sampled.count), 1)
        let closingDistance = hypot(
            points[0].x - points[points.count - 1].x,
            points[0].y - points[points.count - 1].y
        )
        let isClosed = closingDistance < max(24, perimeter * 0.15)

        if !isClosed {
            guard let (start, end) = fitLine(points, length: perimeter) else { return nil }
            return buildStroke(along: [start, end], closed: false, ink: stroke.ink, width: averageWidth)
        }

        let corners = simplify(points, epsilon: max(perimeter * 0.03, 8))
        switch corners.count {
        case 3:
            return buildStroke(along: corners, closed: true, ink: stroke.ink, width: averageWidth)
        case 4:
            return buildStroke(
                along: snapQuadrilateral(corners),
                closed: true,
                ink: stroke.ink,
                width: averageWidth
            )
        default:
            guard let ellipse = fitEllipse(points) else { return nil }
            return buildStroke(along: ellipse, closed: true, ink: stroke.ink, width: averageWidth)
        }
    }

    // MARK: - Fitting

    private static func fitLine(_ points: [CGPoint], length: CGFloat) -> (CGPoint, CGPoint)? {
        guard let first = points.first, let last = points.last else { return nil }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let chord = hypot(dx, dy)
        guard chord > 20 else { return nil }

        var maxDeviation: CGFloat = 0
        for point in points {
            let deviation = abs(dy * (point.x - first.x) - dx * (point.y - first.y)) / chord
            maxDeviation = max(maxDeviation, deviation)
        }
        guard maxDeviation <= max(6, length * 0.045) else { return nil }

        // Snap near-horizontal/vertical lines fully straight.
        var start = first
        var end = last
        let angle = abs(atan2(dy, dx))
        let tolerance: CGFloat = 6 * .pi / 180
        if angle < tolerance || abs(angle - .pi) < tolerance {
            let y = (first.y + last.y) / 2
            start.y = y
            end.y = y
        } else if abs(angle - .pi / 2) < tolerance {
            let x = (first.x + last.x) / 2
            start.x = x
            end.x = x
        }
        return (start, end)
    }

    private static func fitEllipse(_ points: [CGPoint]) -> [CGPoint]? {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let radiusX = (maxX - minX) / 2
        let radiusY = (maxY - minY) / 2
        guard radiusX > 8, radiusY > 8 else { return nil }
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        var totalDeviation: CGFloat = 0
        for point in points {
            let nx = (point.x - center.x) / radiusX
            let ny = (point.y - center.y) / radiusY
            totalDeviation += abs(hypot(nx, ny) - 1)
        }
        guard totalDeviation / CGFloat(points.count) < 0.22 else { return nil }

        var result: [CGPoint] = []
        let steps = 48
        for step in 0...steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            result.append(CGPoint(
                x: center.x + radiusX * cos(angle),
                y: center.y + radiusY * sin(angle)
            ))
        }
        return result
    }

    private static func snapQuadrilateral(_ corners: [CGPoint]) -> [CGPoint] {
        // If the four corners roughly line up with the bounding box, snap to a
        // perfect axis-aligned rectangle; otherwise keep the drawn quadrilateral.
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return corners }
        let boxCorners = [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY)
        ]
        let tolerance = max((maxX - minX), (maxY - minY)) * 0.18

        var remaining = corners
        var matched: [CGPoint] = []
        for boxCorner in boxCorners {
            guard let nearestIndex = remaining.indices.min(by: {
                distance(remaining[$0], boxCorner) < distance(remaining[$1], boxCorner)
            }), distance(remaining[nearestIndex], boxCorner) <= tolerance else {
                return corners
            }
            matched.append(boxCorner)
            remaining.remove(at: nearestIndex)
        }
        return matched
    }

    // MARK: - Geometry helpers

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += distance(points[index - 1], points[index])
        }
        return total
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Ramer–Douglas–Peucker simplification; returns the dominant corners.
    private static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]

        while let (startIndex, endIndex) = stack.popLast() {
            guard endIndex > startIndex + 1 else { continue }
            let start = points[startIndex]
            let end = points[endIndex]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let segmentLength = max(hypot(dx, dy), 0.001)

            var maxDeviation: CGFloat = 0
            var maxIndex = startIndex
            for index in (startIndex + 1)..<endIndex {
                let point = points[index]
                let deviation = abs(dy * (point.x - start.x) - dx * (point.y - start.y)) / segmentLength
                if deviation > maxDeviation {
                    maxDeviation = deviation
                    maxIndex = index
                }
            }
            if maxDeviation > epsilon {
                keep[maxIndex] = true
                stack.append((startIndex, maxIndex))
                stack.append((maxIndex, endIndex))
            }
        }

        var result = points.indices.filter { keep[$0] }.map { points[$0] }
        // The first/last sample of a closed scribble are the same corner —
        // merge them so a rectangle yields 4 corners, not 5.
        if result.count > 2, distance(result[0], result[result.count - 1]) < epsilon * 2 {
            result.removeLast()
        }
        return result
    }

    // MARK: - Stroke construction

    private static func buildStroke(
        along corners: [CGPoint],
        closed: Bool,
        ink: PKInk,
        width: CGFloat
    ) -> PKStroke? {
        guard corners.count >= 2 else { return nil }
        var vertices = corners
        if closed, let first = corners.first {
            vertices.append(first)
        }

        var locations: [CGPoint] = []
        for index in 1..<vertices.count {
            let from = vertices[index - 1]
            let to = vertices[index]
            let segmentLength = distance(from, to)
            let steps = max(Int(segmentLength / 4), 1)
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                locations.append(CGPoint(
                    x: from.x + (to.x - from.x) * t,
                    y: from.y + (to.y - from.y) * t
                ))
            }
            // Repeat the corner so the interpolated path stays sharp there.
            locations.append(to)
            locations.append(to)
        }

        let size = CGSize(width: width, height: width)
        let controlPoints = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.01,
                size: size,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }
}

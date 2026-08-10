import CoreGraphics
import Foundation
import Testing

@testable import Soria

/// Pure geometry, so no serialization needed.
///
/// The spatial-index tests deliberately check against a brute-force scan rather than
/// against hand-written expectations: the grid is an optimization, and the only thing
/// that matters is that it never disagrees with the obvious slow answer.
struct TrackMapLayoutTests {
    private let layout = TrackMapLayout(size: CGSize(width: 400, height: 300), inset: 20)

    /// Deterministic pseudo-random points — a fixed generator keeps the cross-check
    /// reproducible, since a flaky geometry test is worse than none.
    private func makePoints(count: Int) -> [TrackMapPoint] {
        var state: UInt64 = 0x5EED
        func next() -> Double {
            state = (state &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
            return Double((state >> 11) & 0xF_FFFF) / Double(0x10_0000)
        }
        return (0..<count).map { _ in
            TrackMapPoint(id: UUID(), normalized: CGPoint(x: next(), y: next()), colorKey: "k")
        }
    }

    private func bruteForceNearest(
        to viewPoint: CGPoint,
        points: [TrackMapPoint],
        maxDistance: CGFloat
    ) -> UUID? {
        var best: (index: Int, distanceSquared: CGFloat)?
        for (index, point) in points.enumerated() {
            let position = layout.viewPoint(for: point.normalized)
            let dx = position.x - viewPoint.x
            let dy = position.y - viewPoint.y
            let distanceSquared = (dx * dx) + (dy * dy)
            guard distanceSquared <= maxDistance * maxDistance else { continue }
            if let current = best, current.distanceSquared <= distanceSquared { continue }
            best = (index, distanceSquared)
        }
        guard let best else { return nil }
        return points[best.index].id
    }

    // MARK: - Layout

    @Test
    func contentRectHonoursTheInset() {
        #expect(layout.contentRect == CGRect(x: 20, y: 20, width: 360, height: 260))
    }

    @Test
    func normalizedOriginIsBottomLeftAndTopIsTop() {
        // y grows upward in normalized space but downward in view space.
        #expect(layout.viewPoint(for: CGPoint(x: 0, y: 0)) == CGPoint(x: 20, y: 280))
        #expect(layout.viewPoint(for: CGPoint(x: 1, y: 1)) == CGPoint(x: 380, y: 20))
    }

    @Test
    func viewAndNormalizedConversionsRoundTrip() {
        for candidate in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.75), CGPoint(x: 1, y: 1)] {
            let roundTripped = layout.normalizedPoint(for: layout.viewPoint(for: candidate))
            #expect(abs(roundTripped.x - candidate.x) < 1e-9)
            #expect(abs(roundTripped.y - candidate.y) < 1e-9)
        }
    }

    @Test
    func normalizedPointClampsOutsideTheContentRect() {
        let farAbove = layout.normalizedPoint(for: CGPoint(x: -500, y: -500))
        #expect(farAbove == CGPoint(x: 0, y: 1))

        let farBelow = layout.normalizedPoint(for: CGPoint(x: 5000, y: 5000))
        #expect(farBelow == CGPoint(x: 1, y: 0))
    }

    @Test
    func dragDirectionDoesNotChangeTheSelectionRect() {
        let a = CGPoint(x: 40, y: 60)
        let b = CGPoint(x: 200, y: 250)
        let expected = CGRect(x: 40, y: 60, width: 160, height: 190)

        #expect(layout.selectionRect(from: a, to: b) == expected)
        #expect(layout.selectionRect(from: b, to: a) == expected)
        #expect(layout.selectionRect(from: CGPoint(x: a.x, y: b.y), to: CGPoint(x: b.x, y: a.y)) == expected)
        #expect(layout.selectionRect(from: CGPoint(x: b.x, y: a.y), to: CGPoint(x: a.x, y: b.y)) == expected)
    }

    @Test
    func collapsedSizesDoNotDivideByZero() {
        let degenerate = TrackMapLayout(size: .zero, inset: 20)
        #expect(degenerate.contentRect.width >= 1)
        #expect(degenerate.contentRect.height >= 1)

        let point = degenerate.normalizedPoint(for: CGPoint(x: 10, y: 10))
        #expect(point.x.isFinite)
        #expect(point.y.isFinite)
    }

    // MARK: - Spatial index

    @Test
    func nearestPointAgreesWithABruteForceScan() {
        let points = makePoints(count: 500)
        let index = TrackMapSpatialIndex(points: points, layout: layout)
        #expect(index.pointCount == 500)

        // Probe a grid of cursor positions across the whole canvas.
        for stepX in stride(from: 0.0, through: 400.0, by: 17.0) {
            for stepY in stride(from: 0.0, through: 300.0, by: 13.0) {
                let probe = CGPoint(x: stepX, y: stepY)
                let expected = bruteForceNearest(to: probe, points: points, maxDistance: 12)
                #expect(index.nearestPoint(to: probe, maxDistance: 12) == expected)
            }
        }
    }

    @Test
    func nearestPointReturnsNothingBeyondTheRadius() {
        let target = TrackMapPoint(id: UUID(), normalized: CGPoint(x: 0.5, y: 0.5), colorKey: "k")
        let index = TrackMapSpatialIndex(points: [target], layout: layout)
        let center = layout.viewPoint(for: target.normalized)

        #expect(index.nearestPoint(to: center, maxDistance: 6) == target.id)
        #expect(index.nearestPoint(to: CGPoint(x: center.x + 40, y: center.y), maxDistance: 6) == nil)
    }

    @Test
    func emptyIndexIsSafeToQuery() {
        let index = TrackMapSpatialIndex(points: [], layout: layout)
        #expect(index.nearestPoint(to: CGPoint(x: 10, y: 10), maxDistance: 20) == nil)
        #expect(index.points(in: CGRect(x: 0, y: 0, width: 400, height: 300)).isEmpty)
    }

    @Test
    func rectSelectionAgreesWithABruteForceScan() {
        let points = makePoints(count: 500)
        let index = TrackMapSpatialIndex(points: points, layout: layout)
        let rect = CGRect(x: 60, y: 50, width: 180, height: 140)

        let expected = points
            .filter { rect.contains(layout.viewPoint(for: $0.normalized)) }
            .map(\.id)
        let actual = index.points(in: rect)

        #expect(Set(actual) == Set(expected))
        #expect(actual.count == expected.count)
    }

    @Test
    func rectSelectionCoveringEverythingReturnsEveryPoint() {
        let points = makePoints(count: 120)
        let index = TrackMapSpatialIndex(points: points, layout: layout)
        let everything = CGRect(x: -100, y: -100, width: 1000, height: 1000)

        #expect(Set(index.points(in: everything)) == Set(points.map(\.id)))
    }

    @Test
    func rectSelectionOutsideTheCanvasIsEmpty() {
        let points = makePoints(count: 50)
        let index = TrackMapSpatialIndex(points: points, layout: layout)

        #expect(index.points(in: CGRect(x: 900, y: 900, width: 10, height: 10)).isEmpty)
    }
}

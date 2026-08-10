import CoreGraphics
import Foundation

/// Coordinate maths for the similarity map.
///
/// A plain value type with no view attached, following `LibraryPreviewWaveformLayout`:
/// the geometry is the part that is easy to get subtly wrong and hard to notice by
/// eye, so it is kept provable in isolation and the view is left with nothing but
/// event plumbing.
///
/// Normalized space is `[0, 1]` on both axes with **y measured upward**, the way a
/// chart reads. View space has y growing downward, so `viewPoint` flips it.
struct TrackMapLayout {
    let size: CGSize
    let inset: CGFloat

    init(size: CGSize, inset: CGFloat = 18) {
        self.size = size
        self.inset = inset
    }

    /// The drawable area, always at least one point across so nothing divides by zero
    /// during the first layout pass or in a collapsed split view.
    var contentRect: CGRect {
        let usableWidth = max(size.width - (inset * 2), 1)
        let usableHeight = max(size.height - (inset * 2), 1)
        return CGRect(x: inset, y: inset, width: usableWidth, height: usableHeight)
    }

    func viewPoint(for normalized: CGPoint) -> CGPoint {
        let rect = contentRect
        let clampedX = min(max(normalized.x, 0), 1)
        let clampedY = min(max(normalized.y, 0), 1)
        return CGPoint(
            x: rect.minX + (rect.width * clampedX),
            y: rect.maxY - (rect.height * clampedY)
        )
    }

    func normalizedPoint(for viewPoint: CGPoint) -> CGPoint {
        let rect = contentRect
        let x = (viewPoint.x - rect.minX) / rect.width
        let y = (rect.maxY - viewPoint.y) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// The rectangle spanned by a drag, in view space.
    ///
    /// Normalizes direction so dragging up-left selects the same tracks as dragging
    /// down-right across the same two corners.
    func selectionRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

/// Uniform-grid index over the plotted dots.
///
/// Hover fires on every mouse-moved event, and a library can hold thousands of dots;
/// scanning them all each time would burn a lot of work to answer "which dot is under
/// the cursor". Bucketing by cell reduces both hover and rubber-band selection to the
/// handful of dots that could possibly qualify.
struct TrackMapSpatialIndex {
    private let cellSize: CGFloat
    private let origin: CGPoint
    private let columns: Int
    private let rows: Int
    private let buckets: [[Int]]
    private let positions: [CGPoint]
    private let identifiers: [UUID]

    init(points: [TrackMapPoint], layout: TrackMapLayout, cellSize: CGFloat = 24) {
        let rect = layout.contentRect
        let resolvedCellSize = max(cellSize, 1)
        self.cellSize = resolvedCellSize
        self.origin = CGPoint(x: rect.minX, y: rect.minY)
        self.columns = max(Int((rect.width / resolvedCellSize).rounded(.up)), 1)
        self.rows = max(Int((rect.height / resolvedCellSize).rounded(.up)), 1)

        var positions: [CGPoint] = []
        var identifiers: [UUID] = []
        positions.reserveCapacity(points.count)
        identifiers.reserveCapacity(points.count)
        for point in points {
            positions.append(layout.viewPoint(for: point.normalized))
            identifiers.append(point.id)
        }
        self.positions = positions
        self.identifiers = identifiers

        var buckets = [[Int]](repeating: [], count: columns * rows)
        for (index, position) in positions.enumerated() {
            let column = Self.clampedIndex(
                Int(((position.x - rect.minX) / resolvedCellSize).rounded(.down)),
                limit: columns
            )
            let row = Self.clampedIndex(
                Int(((position.y - rect.minY) / resolvedCellSize).rounded(.down)),
                limit: rows
            )
            buckets[(row * columns) + column].append(index)
        }
        self.buckets = buckets
    }

    var pointCount: Int { positions.count }

    /// The nearest dot within `maxDistance` of a view-space point, or nil.
    ///
    /// Ties break on the lowest index so hovering a stack of overlapping dots keeps
    /// reporting the same one rather than flickering between them.
    func nearestPoint(to viewPoint: CGPoint, maxDistance: CGFloat) -> UUID? {
        guard !positions.isEmpty, maxDistance > 0 else { return nil }

        // Widen the search by however many cells the radius spans.
        let reach = max(Int((maxDistance / cellSize).rounded(.up)), 1)
        let centerColumn = Int(((viewPoint.x - origin.x) / cellSize).rounded(.down))
        let centerRow = Int(((viewPoint.y - origin.y) / cellSize).rounded(.down))

        var bestIndex: Int?
        var bestDistanceSquared = maxDistance * maxDistance

        for row in (centerRow - reach)...(centerRow + reach) {
            guard row >= 0, row < rows else { continue }
            for column in (centerColumn - reach)...(centerColumn + reach) {
                guard column >= 0, column < columns else { continue }
                for index in buckets[(row * columns) + column] {
                    let position = positions[index]
                    let dx = position.x - viewPoint.x
                    let dy = position.y - viewPoint.y
                    let distanceSquared = (dx * dx) + (dy * dy)
                    guard distanceSquared <= bestDistanceSquared else { continue }
                    if distanceSquared == bestDistanceSquared, let bestIndex, index >= bestIndex {
                        continue
                    }
                    bestDistanceSquared = distanceSquared
                    bestIndex = index
                }
            }
        }

        guard let bestIndex else { return nil }
        return identifiers[bestIndex]
    }

    /// Every dot whose centre falls inside a view-space rectangle.
    func points(in rect: CGRect) -> [UUID] {
        guard !positions.isEmpty else { return [] }

        let minColumn = Self.clampedIndex(Int(((rect.minX - origin.x) / cellSize).rounded(.down)), limit: columns)
        let maxColumn = Self.clampedIndex(Int(((rect.maxX - origin.x) / cellSize).rounded(.down)), limit: columns)
        let minRow = Self.clampedIndex(Int(((rect.minY - origin.y) / cellSize).rounded(.down)), limit: rows)
        let maxRow = Self.clampedIndex(Int(((rect.maxY - origin.y) / cellSize).rounded(.down)), limit: rows)

        var matched: [Int] = []
        for row in minRow...maxRow {
            for column in minColumn...maxColumn {
                for index in buckets[(row * columns) + column] where rect.contains(positions[index]) {
                    matched.append(index)
                }
            }
        }

        // Stable order regardless of how the grid was walked.
        return matched.sorted().map { identifiers[$0] }
    }

    private static func clampedIndex(_ value: Int, limit: Int) -> Int {
        min(max(value, 0), max(limit - 1, 0))
    }
}

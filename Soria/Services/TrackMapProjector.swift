import Accelerate
import CoreGraphics
import Foundation

/// Projects high-dimensional audio embeddings onto a plane so the library can be
/// drawn as a scatter of dots.
///
/// Principal component analysis, computed by power iteration on the two leading
/// components rather than by forming a covariance matrix: at 3072 dimensions that
/// matrix would hold 9.4 million entries, and only two eigenvectors are ever
/// wanted.
///
/// Everything here is deterministic and pure — no randomness, no clock, no I/O — so
/// the same library always produces the same map, and the whole file is testable
/// without a database or a view. Determinism is a feature, not an accident: a map
/// that reshuffled itself between launches would be useless for recognising the
/// same cluster twice.
enum TrackMapProjector {
    /// Upper bound on power-iteration passes.
    ///
    /// Generous because it is almost never reached: convergence depends on how far
    /// apart neighbouring eigenvalues are, and on real embeddings the loop settles in
    /// well under a hundred passes and exits. The high cap only costs anything for
    /// near-degenerate samples, where the two axes are interchangeable anyway.
    static let defaultIterations = 512

    /// How closely successive iterates must point the same way before stopping.
    ///
    /// Measured on the direction rather than the eigenvalue on purpose: the
    /// eigenvalue estimate converges roughly as the square of the eigenvector error,
    /// so a tolerance applied to it stops while the axis itself is still visibly off.
    private static let directionTolerance = 1e-15

    // MARK: - Basis

    /// Derives the mean vector and top two principal components from a sample.
    ///
    /// Returns nil when there is nothing meaningful to project: fewer than two
    /// usable vectors, or a sample with no variance at all (every track identical).
    /// Vectors whose length differs from the dominant dimension are ignored rather
    /// than treated as an error — a half-migrated library should still get a map.
    static func computeBasis(
        vectors: [[Double]],
        profileID: String,
        iterations: Int = defaultIterations
    ) -> TrackMapProjectionBasis? {
        guard let dimension = dominantDimension(of: vectors), dimension > 0 else { return nil }

        let usable = vectors.filter { $0.count == dimension }
        guard usable.count >= 2 else { return nil }

        let rowCount = usable.count
        let mean = meanVector(of: usable, dimension: dimension)

        // Row-major centered sample matrix, rowCount x dimension.
        var centered = [Double](repeating: 0, count: rowCount * dimension)
        for (rowIndex, vector) in usable.enumerated() {
            let offset = rowIndex * dimension
            for column in 0..<dimension {
                centered[offset + column] = vector[column] - mean[column]
            }
        }

        let totalVariance = centered.reduce(0) { $0 + ($1 * $1) }
        guard totalVariance > .ulpOfOne else { return nil }

        guard
            let first = leadingComponent(
                centered: centered,
                rowCount: rowCount,
                dimension: dimension,
                orthogonalTo: [],
                iterations: iterations
            )
        else { return nil }

        // A second component only exists if the sample spans more than one axis.
        let second = leadingComponent(
            centered: centered,
            rowCount: rowCount,
            dimension: dimension,
            orthogonalTo: [first.vector],
            iterations: iterations
        )

        let componentY = second?.vector ?? fallbackOrthogonalVector(to: first.vector)
        let explained = (first.eigenvalue + (second?.eigenvalue ?? 0)) / totalVariance

        return TrackMapProjectionBasis(
            profileID: profileID,
            dimension: dimension,
            mean: mean,
            componentX: first.vector,
            componentY: componentY,
            explainedVarianceRatio: min(max(explained, 0), 1),
            sourceTrackCount: rowCount
        )
    }

    /// Places one vector on the plane defined by a stored basis.
    ///
    /// Cheap by design — two dot products — so a track analyzed after the basis was
    /// built lands in the right place without recomputing anything.
    static func project(_ vector: [Double], using basis: TrackMapProjectionBasis) -> CGPoint? {
        guard basis.isUsable, vector.count == basis.dimension else { return nil }

        var x = 0.0
        var y = 0.0
        for index in 0..<basis.dimension {
            let centered = vector[index] - basis.mean[index]
            x += centered * basis.componentX[index]
            y += centered * basis.componentY[index]
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Display normalization

    /// Rescales raw values into `[0, 1]`, clipping the extreme tails first.
    ///
    /// Without clipping a handful of outliers stretch the axis so far that every
    /// other dot collapses into a single blob. Values outside the percentile window
    /// are pinned to the edge rather than dropped, so no track silently vanishes
    /// from the map.
    static func normalizedValues(
        _ values: [UUID: Double],
        clipPercentile: Double = 0.02
    ) -> [UUID: Double] {
        guard !values.isEmpty else { return [:] }

        let sorted = values.values.sorted()
        let (lower, upper) = clipBounds(sorted: sorted, percentile: clipPercentile)
        let span = upper - lower

        // Every value identical: put them all down the middle instead of dividing by zero.
        guard span > .ulpOfOne else {
            return values.mapValues { _ in 0.5 }
        }

        return values.mapValues { value in
            min(max((value - lower) / span, 0), 1)
        }
    }

    /// Normalizes both axes of a point cloud independently.
    static func normalizedPoints(
        _ points: [UUID: CGPoint],
        clipPercentile: Double = 0.02
    ) -> [UUID: CGPoint] {
        guard !points.isEmpty else { return [:] }

        let xs = normalizedValues(points.mapValues { Double($0.x) }, clipPercentile: clipPercentile)
        let ys = normalizedValues(points.mapValues { Double($0.y) }, clipPercentile: clipPercentile)

        var output: [UUID: CGPoint] = [:]
        output.reserveCapacity(points.count)
        for id in points.keys {
            guard let x = xs[id], let y = ys[id] else { continue }
            output[id] = CGPoint(x: x, y: y)
        }
        return output
    }

    // MARK: - Private

    private struct Component {
        let vector: [Double]
        let eigenvalue: Double
    }

    /// The length shared by the most vectors. Using the mode rather than the first
    /// vector's length keeps one stray row from disqualifying the whole library.
    private static func dominantDimension(of vectors: [[Double]]) -> Int? {
        var counts: [Int: Int] = [:]
        for vector in vectors where !vector.isEmpty {
            counts[vector.count, default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        // Sort for determinism: highest count wins, smallest dimension breaks ties.
        return counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.first?.key
    }

    /// vDSP calls below always route the destination through an explicit mutable
    /// buffer pointer instead of `&array`. Passing the same array as both a read
    /// argument and an `inout` argument is overlapping access, which Swift's
    /// exclusivity checking can trap on at runtime.
    private static func meanVector(of vectors: [[Double]], dimension: Int) -> [Double] {
        var mean = [Double](repeating: 0, count: dimension)
        mean.withUnsafeMutableBufferPointer { accumulator in
            guard let target = accumulator.baseAddress else { return }
            for vector in vectors {
                vDSP_vaddD(target, 1, vector, 1, target, 1, vDSP_Length(dimension))
            }
            var divisor = Double(vectors.count)
            vDSP_vsdivD(target, 1, &divisor, target, 1, vDSP_Length(dimension))
        }
        return mean
    }

    /// Power iteration for the leading eigenvector of `Xᵀ X`, optionally restricted
    /// to the subspace orthogonal to components already found.
    ///
    /// `Xᵀ X` is never materialized; each pass applies `X` then `Xᵀ`. Both products
    /// run as serial loops over rows rather than a BLAS matrix call, because a
    /// parallel reduction may sum rows in a different order run to run, and that
    /// would put determinism at the mercy of thread scheduling.
    private static func leadingComponent(
        centered: [Double],
        rowCount: Int,
        dimension: Int,
        orthogonalTo previous: [[Double]],
        iterations: Int
    ) -> Component? {
        var vector = seedVector(dimension: dimension)
        orthogonalize(&vector, against: previous)
        guard normalizeInPlace(&vector) else { return nil }

        var rowProjections = [Double](repeating: 0, count: rowCount)
        var next = [Double](repeating: 0, count: dimension)
        var previousIterate = vector
        var eigenvalue = 0.0

        for iteration in 0..<max(iterations, 1) {
            // rowProjections = X v
            centered.withUnsafeBufferPointer { matrix in
                guard let base = matrix.baseAddress else { return }
                for row in 0..<rowCount {
                    var dot = 0.0
                    vDSP_dotprD(base + (row * dimension), 1, vector, 1, &dot, vDSP_Length(dimension))
                    rowProjections[row] = dot
                }
            }

            // next = Xᵀ (X v)
            next.withUnsafeMutableBufferPointer { accumulator in
                guard let target = accumulator.baseAddress else { return }
                vDSP_vclrD(target, 1, vDSP_Length(dimension))
                centered.withUnsafeBufferPointer { matrix in
                    guard let base = matrix.baseAddress else { return }
                    for row in 0..<rowCount {
                        var scale = rowProjections[row]
                        guard scale != 0 else { continue }
                        vDSP_vsmaD(base + (row * dimension), 1, &scale, target, 1, target, 1, vDSP_Length(dimension))
                    }
                }
            }

            orthogonalize(&next, against: previous)

            var magnitude = 0.0
            vDSP_dotprD(next, 1, next, 1, &magnitude, vDSP_Length(dimension))
            magnitude = magnitude.squareRoot()

            // Collapsed to nothing: the sample has no variance left on this axis.
            guard magnitude > .ulpOfOne else { return nil }

            var inverse = 1.0 / magnitude
            vector.withUnsafeMutableBufferPointer { unit in
                guard let target = unit.baseAddress else { return }
                vDSP_vsmulD(next, 1, &inverse, target, 1, vDSP_Length(dimension))
            }

            eigenvalue = magnitude

            // Both iterates are unit length, so their dot product is the cosine of
            // the angle between them; |cos| because a converged axis may alternate
            // sign between passes when the eigenvalue is negative-adjacent.
            var alignment = 0.0
            vDSP_dotprD(vector, 1, previousIterate, 1, &alignment, vDSP_Length(dimension))
            if iteration > 0, abs(abs(alignment) - 1.0) <= directionTolerance {
                break
            }
            previousIterate = vector
        }

        canonicalizeSign(&vector)
        guard eigenvalue > .ulpOfOne else { return nil }
        return Component(vector: vector, eigenvalue: eigenvalue)
    }

    /// A fixed, non-degenerate starting vector.
    ///
    /// `sin(i + 1)` rather than a random draw: power iteration converges from almost
    /// any start, but only a fixed start makes the result reproducible.
    private static func seedVector(dimension: Int) -> [Double] {
        (0..<dimension).map { Foundation.sin(Double($0 + 1)) }
    }

    private static func orthogonalize(_ vector: inout [Double], against others: [[Double]]) {
        let count = vector.count
        vector.withUnsafeMutableBufferPointer { buffer in
            guard let target = buffer.baseAddress else { return }
            for other in others where other.count == count {
                var dot = 0.0
                vDSP_dotprD(target, 1, other, 1, &dot, vDSP_Length(count))
                var scale = -dot
                vDSP_vsmaD(other, 1, &scale, target, 1, target, 1, vDSP_Length(count))
            }
        }
    }

    @discardableResult
    private static func normalizeInPlace(_ vector: inout [Double]) -> Bool {
        let count = vector.count
        return vector.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let target = buffer.baseAddress else { return false }
            var magnitude = 0.0
            vDSP_dotprD(target, 1, target, 1, &magnitude, vDSP_Length(count))
            magnitude = magnitude.squareRoot()
            guard magnitude > .ulpOfOne else { return false }
            var inverse = 1.0 / magnitude
            vDSP_vsmulD(target, 1, &inverse, target, 1, vDSP_Length(count))
            return true
        }
    }

    /// Fixes the arbitrary sign of an eigenvector.
    ///
    /// `v` and `-v` are equally valid principal components, so without this the map
    /// could come back mirrored after a recompute and every remembered cluster
    /// position would be wrong. Anchoring on the largest-magnitude coordinate (lowest
    /// index wins ties) makes the choice stable.
    private static func canonicalizeSign(_ vector: inout [Double]) {
        var anchorIndex = 0
        var anchorMagnitude = 0.0
        for (index, value) in vector.enumerated() where abs(value) > anchorMagnitude {
            anchorMagnitude = abs(value)
            anchorIndex = index
        }
        guard vector[anchorIndex] < 0 else { return }
        let count = vector.count
        vector.withUnsafeMutableBufferPointer { buffer in
            guard let target = buffer.baseAddress else { return }
            var negativeOne = -1.0
            vDSP_vsmulD(target, 1, &negativeOne, target, 1, vDSP_Length(count))
        }
    }

    /// Some axis is needed for Y even when the sample is effectively one-dimensional.
    /// Every track then shares the same Y, which the display normalization renders as
    /// a flat line — an honest picture of a one-dimensional library.
    private static func fallbackOrthogonalVector(to vector: [Double]) -> [Double] {
        [Double](repeating: 0, count: vector.count)
    }

    private static func clipBounds(sorted: [Double], percentile: Double) -> (lower: Double, upper: Double) {
        guard let first = sorted.first, let last = sorted.last else { return (0, 0) }
        let clamped = min(max(percentile, 0), 0.4)
        guard sorted.count > 2, clamped > 0 else { return (first, last) }

        let maxIndex = sorted.count - 1
        let lowerIndex = Int((Double(maxIndex) * clamped).rounded(.down))
        let upperIndex = Int((Double(maxIndex) * (1 - clamped)).rounded(.up))
        return (sorted[lowerIndex], sorted[min(upperIndex, maxIndex)])
    }
}

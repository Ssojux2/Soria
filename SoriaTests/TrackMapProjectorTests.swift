import CoreGraphics
import Foundation
import Testing

@testable import Soria

/// Pure maths, no disk or database, so this suite can run in parallel.
///
/// The determinism and sign-stability tests carry the most weight here: the map is
/// meant to be a place a user learns, and a projection that quietly rotated or
/// mirrored between launches would break that without ever failing loudly.
struct TrackMapProjectorTests {
    // MARK: - Helpers

    /// Points spread widely along axis 0 and narrowly along axis 1, so the leading
    /// component has a known answer.
    private func syntheticVectors(count: Int = 24, dimension: Int = 6) -> [[Double]] {
        (0..<count).map { index in
            var vector = [Double](repeating: 0, count: dimension)
            let t = Double(index) - (Double(count) / 2.0)
            vector[0] = t * 10.0
            vector[1] = Foundation.sin(Double(index)) * 0.5
            return vector
        }
    }

    private func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + ($1.0 * $1.1) }
    }

    // MARK: - Correctness

    @Test
    func leadingComponentFindsTheAxisWithTheMostSpread() throws {
        let basis = try #require(
            TrackMapProjector.computeBasis(vectors: syntheticVectors(), profileID: "test")
        )

        #expect(basis.dimension == 6)
        #expect(basis.sourceTrackCount == 24)
        // Nearly all the variance is on axis 0, so component X should align with it.
        #expect(abs(basis.componentX[0]) > 0.99)
        #expect(abs(basis.componentX[2]) < 0.01)
    }

    @Test
    func componentsAreUnitLengthAndOrthogonal() throws {
        let basis = try #require(
            TrackMapProjector.computeBasis(vectors: syntheticVectors(), profileID: "test")
        )

        #expect(abs(dot(basis.componentX, basis.componentX) - 1.0) < 1e-8)
        #expect(abs(dot(basis.componentY, basis.componentY) - 1.0) < 1e-8)
        #expect(abs(dot(basis.componentX, basis.componentY)) < 1e-8)
    }

    @Test
    func explainedVarianceStaysInRangeAndIsHighForPlanarData() throws {
        // All variance lives in two dimensions, so two components should capture it.
        let vectors = (0..<40).map { index -> [Double] in
            var vector = [Double](repeating: 0, count: 5)
            vector[0] = Double(index)
            vector[1] = Double(index % 7)
            return vector
        }
        let basis = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))

        #expect(basis.explainedVarianceRatio > 0.99)
        #expect(basis.explainedVarianceRatio <= 1.0)
    }

    /// The strongest available check that power iteration actually converged:
    /// a principal component must satisfy `XᵀX v = λv`. Verifying the defining
    /// property needs no reference implementation to compare against.
    @Test
    func componentsSatisfyTheEigenvectorEquation() throws {
        let dimension = 12
        var state: UInt64 = 0xC0FFEE
        func next() -> Double {
            state = (state &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
            return (Double((state >> 11) & 0xF_FFFF) / Double(0x10_0000)) - 0.5
        }
        let vectors = (0..<80).map { _ in (0..<dimension).map { _ in next() * 4 } }

        let basis = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))
        let centered = vectors.map { vector in
            (0..<dimension).map { vector[$0] - basis.mean[$0] }
        }

        for component in [basis.componentX, basis.componentY] {
            // applied = XᵀX v
            var applied = [Double](repeating: 0, count: dimension)
            for row in centered {
                let projection = dot(row, component)
                for index in 0..<dimension {
                    applied[index] += projection * row[index]
                }
            }

            let eigenvalue = dot(applied, component)
            let residual = (0..<dimension)
                .map { applied[$0] - (eigenvalue * component[$0]) }
                .reduce(0) { $0 + ($1 * $1) }
                .squareRoot()

            #expect(eigenvalue > 0)
            #expect(residual / eigenvalue < 1e-6)
        }
    }

    /// Exercises the real shape of the problem — a few hundred tracks at the 3072
    /// dimensions the Gemini profile produces — so a scaling mistake shows up here
    /// rather than the first time someone opens the tab.
    @Test
    func handlesLibraryScaleDimensionality() throws {
        let dimension = 3072
        var state: UInt64 = 0xBEEF
        func next() -> Double {
            state = (state &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
            return (Double((state >> 11) & 0xF_FFFF) / Double(0x10_0000)) - 0.5
        }
        // Three latent groups plus noise, which is roughly how audio embeddings sit.
        let vectors = (0..<400).map { index -> [Double] in
            let group = index % 3
            return (0..<dimension).map { axis in
                let signal = axis % 3 == group ? 1.0 : 0.0
                return signal + (next() * 0.1)
            }
        }

        let basis = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))

        #expect(basis.dimension == dimension)
        #expect(basis.sourceTrackCount == 400)
        #expect(abs(dot(basis.componentX, basis.componentX) - 1.0) < 1e-8)
        #expect(abs(dot(basis.componentX, basis.componentY)) < 1e-6)
        #expect(basis.explainedVarianceRatio > 0)
        #expect(basis.explainedVarianceRatio <= 1.0)

        // The three planted groups must not collapse onto one another.
        let projected = vectors.map { TrackMapProjector.project($0, using: basis) }
        let placed = projected.compactMap { $0 }
        #expect(placed.count == vectors.count)
        let spreadX = (placed.map(\.x).max() ?? 0) - (placed.map(\.x).min() ?? 0)
        #expect(spreadX > 0)
    }

    // MARK: - Determinism

    @Test
    func repeatedRunsProduceIdenticalBases() throws {
        let vectors = syntheticVectors()
        let first = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))
        let second = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))

        #expect(first == second)
    }

    @Test
    func inputOrderingDoesNotMoveTheProjection() throws {
        let vectors = syntheticVectors()
        // A fixed shuffle keeps the test itself deterministic.
        let reordered = Array(vectors.reversed())

        let straight = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))
        let shuffled = try #require(TrackMapProjector.computeBasis(vectors: reordered, profileID: "test"))

        for index in 0..<straight.dimension {
            #expect(abs(straight.mean[index] - shuffled.mean[index]) < 1e-9)
            #expect(abs(straight.componentX[index] - shuffled.componentX[index]) < 1e-7)
            #expect(abs(straight.componentY[index] - shuffled.componentY[index]) < 1e-7)
        }

        // The thing that actually matters: a given track lands in the same spot.
        let probe = vectors[3]
        let a = try #require(TrackMapProjector.project(probe, using: straight))
        let b = try #require(TrackMapProjector.project(probe, using: shuffled))
        #expect(abs(a.x - b.x) < 1e-6)
        #expect(abs(a.y - b.y) < 1e-6)
    }

    @Test
    func signIsCanonicalSoTheMapNeverMirrors() throws {
        let vectors = syntheticVectors()
        // Negating every sample flips the natural eigenvector direction; sign
        // canonicalization has to undo that or the whole map would mirror.
        let negated = vectors.map { $0.map { value in -value } }

        let straight = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))
        let flipped = try #require(TrackMapProjector.computeBasis(vectors: negated, profileID: "test"))

        let anchor = straight.componentX.enumerated().max { abs($0.element) < abs($1.element) }
        let anchorIndex = try #require(anchor).offset
        #expect(straight.componentX[anchorIndex] > 0)
        #expect(flipped.componentX[anchorIndex] > 0)
    }

    // MARK: - Degenerate input

    @Test
    func emptyInputProducesNoBasis() {
        #expect(TrackMapProjector.computeBasis(vectors: [], profileID: "test") == nil)
    }

    @Test
    func singleVectorProducesNoBasis() {
        #expect(TrackMapProjector.computeBasis(vectors: [[1, 2, 3]], profileID: "test") == nil)
    }

    @Test
    func identicalVectorsProduceNoBasis() {
        // No variance at all: there is no meaningful plane to project onto, and
        // returning a basis anyway would draw a fake map.
        let vectors = [[Double]](repeating: [1, 2, 3, 4], count: 12)
        #expect(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test") == nil)
    }

    @Test
    func mismatchedDimensionsAreIgnoredRatherThanFatal() throws {
        var vectors = syntheticVectors()
        vectors.append([1, 2])
        vectors.append([])

        let basis = try #require(TrackMapProjector.computeBasis(vectors: vectors, profileID: "test"))
        #expect(basis.dimension == 6)
        #expect(basis.sourceTrackCount == 24)
    }

    @Test
    func projectingRejectsAWrongLengthVector() throws {
        let basis = try #require(
            TrackMapProjector.computeBasis(vectors: syntheticVectors(), profileID: "test")
        )
        #expect(TrackMapProjector.project([1, 2, 3], using: basis) == nil)
    }

    // MARK: - Display normalization

    @Test
    func normalizationClipsOutliersWithoutDroppingThem() {
        var values: [UUID: Double] = [:]
        var ids: [UUID] = []
        for index in 0..<100 {
            let id = UUID()
            ids.append(id)
            values[id] = Double(index)
        }
        let outlier = UUID()
        values[outlier] = 1_000_000

        let normalized = TrackMapProjector.normalizedValues(values, clipPercentile: 0.02)

        // Nothing disappears, and everything lands inside the unit range.
        #expect(normalized.count == values.count)
        #expect(normalized.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        // The outlier is pinned to the edge rather than stretching the axis.
        #expect(normalized[outlier] == 1.0)
        // The bulk still spreads out instead of collapsing next to the outlier.
        let bulk = ids.compactMap { normalized[$0] }
        let spread = (bulk.max() ?? 0) - (bulk.min() ?? 0)
        #expect(spread > 0.9)
    }

    @Test
    func identicalValuesLandDownTheMiddle() {
        let values = Dictionary(uniqueKeysWithValues: (0..<5).map { _ in (UUID(), 42.0) })
        let normalized = TrackMapProjector.normalizedValues(values)

        #expect(normalized.count == 5)
        #expect(normalized.values.allSatisfy { $0 == 0.5 })
    }

    @Test
    func normalizingAnEmptySetIsEmpty() {
        #expect(TrackMapProjector.normalizedValues([:]).isEmpty)
        #expect(TrackMapProjector.normalizedPoints([:]).isEmpty)
    }

    @Test
    func pointNormalizationScalesEachAxisIndependently() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let points: [UUID: CGPoint] = [
            a: CGPoint(x: 0, y: 0),
            b: CGPoint(x: 10, y: 1000),
            c: CGPoint(x: 5, y: 500),
        ]

        let normalized = TrackMapProjector.normalizedPoints(points, clipPercentile: 0)

        #expect(normalized[a] == CGPoint(x: 0, y: 0))
        #expect(normalized[b] == CGPoint(x: 1, y: 1))
        let middle = normalized[c]
        #expect(abs((middle?.x ?? 0) - 0.5) < 1e-9)
        #expect(abs((middle?.y ?? 0) - 0.5) < 1e-9)
    }
}

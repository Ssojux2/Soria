import AppKit
import SwiftUI

/// Colour assignment for map dots and the legend that explains them.
///
/// System colours rather than fixed hex values so the map stays legible when the
/// user switches between light and dark appearance.
enum TrackMapPalette {
    /// Reserved key for "no value" — untagged genre, no folder, and so on.
    static let unassignedKey = ""

    static let colors: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemPink, .systemTeal, .systemRed, .systemIndigo,
        .systemYellow, .systemBrown, .systemMint, .systemCyan,
    ]

    static let unassignedColor = NSColor.systemGray

    /// Maps colour keys to palette slots in sorted order.
    ///
    /// Sorting rather than first-seen order means a track's colour does not change
    /// just because the library was loaded in a different sequence. Keys beyond the
    /// palette wrap around; with more than twelve groups some colours repeat, which
    /// the legend still disambiguates by name.
    static func assignments(for keys: some Sequence<String>) -> [String: NSColor] {
        let distinct = Set(keys).subtracting([unassignedKey]).sorted()
        var output: [String: NSColor] = [unassignedKey: unassignedColor]
        for (index, key) in distinct.enumerated() {
            output[key] = colors[index % colors.count]
        }
        return output
    }
}

/// The scatter plot itself.
///
/// AppKit rather than SwiftUI `Canvas` because this screen needs hover tracking and
/// rubber-band drag over thousands of hit-testable dots, and the app already draws
/// its one other interactive graphic (the waveform) this way — SwiftUI gestures are
/// used nowhere in this codebase.
struct TrackMapCanvas: NSViewRepresentable {
    let points: [TrackMapPoint]
    let colorsByKey: [String: NSColor]
    let selectedTrackIDs: Set<UUID>
    let hoveredTrackID: UUID?
    /// When set, every dot with a different key is drawn faded so one legend group
    /// can be picked out of the crowd.
    let highlightedColorKey: String?
    let onHoverChanged: (UUID?) -> Void
    let onSelectionChanged: (Set<UUID>, Bool) -> Void

    func makeNSView(context: Context) -> TrackMapPlotView {
        let view = TrackMapPlotView()
        view.apply(
            points: points,
            colorsByKey: colorsByKey,
            selectedTrackIDs: selectedTrackIDs,
            hoveredTrackID: hoveredTrackID,
            highlightedColorKey: highlightedColorKey
        )
        view.onHoverChanged = onHoverChanged
        view.onSelectionChanged = onSelectionChanged
        return view
    }

    func updateNSView(_ nsView: TrackMapPlotView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onSelectionChanged = onSelectionChanged
        nsView.apply(
            points: points,
            colorsByKey: colorsByKey,
            selectedTrackIDs: selectedTrackIDs,
            hoveredTrackID: hoveredTrackID,
            highlightedColorKey: highlightedColorKey
        )
    }
}

final class TrackMapPlotView: NSView {
    /// How far the pointer may travel before a click becomes a rubber-band drag.
    /// Same idea as the waveform's press-intent slop: without it, the hand tremor in
    /// an ordinary click turns into a one-pixel selection rectangle that clears the
    /// user's selection.
    private static let dragSlop: CGFloat = 4
    private static let hoverRadius: CGFloat = 9
    private static let dotRadius: CGFloat = 3
    private static let selectedDotRadius: CGFloat = 5

    var onHoverChanged: (UUID?) -> Void = { _ in }
    var onSelectionChanged: (Set<UUID>, Bool) -> Void = { _, _ in }

    private var points: [TrackMapPoint] = []
    private var colorsByKey: [String: NSColor] = [:]
    private var selectedTrackIDs: Set<UUID> = []
    private var hoveredTrackID: UUID?
    private var highlightedColorKey: String?

    private var layout = TrackMapLayout(size: .zero)
    private var spatialIndex = TrackMapSpatialIndex(points: [], layout: TrackMapLayout(size: .zero))
    private var positionsByTrackID: [UUID: CGPoint] = [:]

    /// Rebuilt only when the dots or the canvas size change, not when selection or
    /// hover moves — those are cheap overlays drawn on top of the cached geometry.
    private var cachedFills: [(key: String, color: NSColor, path: CGPath)] = []
    private var needsGeometryRebuild = true

    private var trackingAreaToken: NSTrackingArea?
    private var dragOrigin: CGPoint?
    private var rubberBandRect: CGRect?
    private var isAdditiveDrag = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Input from SwiftUI

    func apply(
        points: [TrackMapPoint],
        colorsByKey: [String: NSColor],
        selectedTrackIDs: Set<UUID>,
        hoveredTrackID: UUID?,
        highlightedColorKey: String?
    ) {
        let geometryChanged = points != self.points || colorsByKey != self.colorsByKey
        let overlayChanged = selectedTrackIDs != self.selectedTrackIDs
            || hoveredTrackID != self.hoveredTrackID
            || highlightedColorKey != self.highlightedColorKey

        self.points = points
        self.colorsByKey = colorsByKey
        self.selectedTrackIDs = selectedTrackIDs
        self.hoveredTrackID = hoveredTrackID
        self.highlightedColorKey = highlightedColorKey

        if geometryChanged {
            needsGeometryRebuild = true
        }
        if geometryChanged || overlayChanged {
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsGeometryRebuild = true
        needsDisplay = true
    }

    // MARK: - Geometry

    private func rebuildGeometryIfNeeded() {
        guard needsGeometryRebuild else { return }
        needsGeometryRebuild = false

        layout = TrackMapLayout(size: bounds.size)
        spatialIndex = TrackMapSpatialIndex(points: points, layout: layout)

        var positions: [UUID: CGPoint] = [:]
        positions.reserveCapacity(points.count)
        var pathsByKey: [String: CGMutablePath] = [:]

        for point in points {
            let position = layout.viewPoint(for: point.normalized)
            positions[point.id] = position

            let path = pathsByKey[point.colorKey] ?? CGMutablePath()
            path.addEllipse(
                in: CGRect(
                    x: position.x - Self.dotRadius,
                    y: position.y - Self.dotRadius,
                    width: Self.dotRadius * 2,
                    height: Self.dotRadius * 2
                )
            )
            pathsByKey[point.colorKey] = path
        }

        positionsByTrackID = positions
        // Sorted so draw order — and therefore which dots end up on top where they
        // overlap — does not shift between rebuilds.
        cachedFills = pathsByKey.keys.sorted().compactMap { key in
            guard let path = pathsByKey[key] else { return nil }
            return (key, colorsByKey[key] ?? TrackMapPalette.unassignedColor, path)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        rebuildGeometryIfNeeded()

        let plot = layout.contentRect
        NSColor.textBackgroundColor.setFill()
        context.fill(bounds)

        // A faint frame so an empty or sparse map still reads as a plotting area.
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.stroke(plot.insetBy(dx: -0.5, dy: -0.5))

        for fill in cachedFills {
            // Compare keys, not colours: the palette wraps past twelve groups, so two
            // unrelated groups can share a colour and highlighting one must not
            // light up the other.
            let isHighlighted = highlightedColorKey == nil || highlightedColorKey == fill.key
            context.setFillColor(fill.color.withAlphaComponent(isHighlighted ? 0.85 : 0.12).cgColor)
            context.addPath(fill.path)
            context.fillPath()
        }

        drawSelectionRings(in: context)
        drawHoverRing(in: context)
        drawRubberBand(in: context)
    }

    private func drawSelectionRings(in context: CGContext) {
        guard !selectedTrackIDs.isEmpty else { return }

        let ring = CGMutablePath()
        for trackID in selectedTrackIDs {
            guard let position = positionsByTrackID[trackID] else { continue }
            ring.addEllipse(
                in: CGRect(
                    x: position.x - Self.selectedDotRadius,
                    y: position.y - Self.selectedDotRadius,
                    width: Self.selectedDotRadius * 2,
                    height: Self.selectedDotRadius * 2
                )
            )
        }
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1.5)
        context.addPath(ring)
        context.strokePath()
    }

    private func drawHoverRing(in context: CGContext) {
        guard let hoveredTrackID, let position = positionsByTrackID[hoveredTrackID] else { return }
        let radius = Self.selectedDotRadius + 2
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(
            in: CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    }

    private func drawRubberBand(in context: CGContext) {
        guard let rubberBandRect else { return }
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
        context.fill(rubberBandRect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.stroke(rubberBandRect)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }
        let options: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .mouseMoved,
            .enabledDuringMouseDrag,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaToken = area
    }

    override func mouseMoved(with event: NSEvent) {
        rebuildGeometryIfNeeded()
        let location = convert(event.locationInWindow, from: nil)
        let hit = spatialIndex.nearestPoint(to: location, maxDistance: Self.hoverRadius)
        guard hit != hoveredTrackID else { return }
        onHoverChanged(hit)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredTrackID != nil else { return }
        onHoverChanged(nil)
    }

    override func mouseDown(with event: NSEvent) {
        rebuildGeometryIfNeeded()
        dragOrigin = convert(event.locationInWindow, from: nil)
        isAdditiveDrag = event.modifierFlags.contains(.shift)
        rubberBandRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let location = convert(event.locationInWindow, from: nil)
        let travelled = hypot(location.x - dragOrigin.x, location.y - dragOrigin.y)
        guard travelled > Self.dragSlop else { return }

        rubberBandRect = layout.selectionRect(from: dragOrigin, to: location)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            rubberBandRect = nil
            needsDisplay = true
        }
        guard dragOrigin != nil else { return }

        // A drag selects the region; a click selects the dot under the cursor, and
        // clicking empty space clears — the same convention as the library table.
        if let rubberBandRect {
            let hits = Set(spatialIndex.points(in: rubberBandRect))
            onSelectionChanged(hits, isAdditiveDrag)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        if let hit = spatialIndex.nearestPoint(to: location, maxDistance: Self.hoverRadius) {
            onSelectionChanged([hit], isAdditiveDrag)
        } else if !isAdditiveDrag {
            onSelectionChanged([], false)
        }
    }
}

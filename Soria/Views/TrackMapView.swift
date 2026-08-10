import AppKit
import SwiftUI

/// The Map tab: the library as a scatter of dots you can compare and group.
///
/// The Organizer's other tabs answer "what did the AI decide?" with a table. This one
/// answers "does that decision actually hold together?" — you can see whether a genre
/// really clusters, check two tracks against each other, and lasso a region into a
/// folder.
struct TrackMapView: View {
    @ObservedObject var model: TrackMapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            statusCard
            canvasCard
            actionCard
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("organizer-map-view")
        .onAppear { model.refreshIfNeeded() }
    }

    // MARK: - Controls

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Picker("Layout", selection: $model.layoutMode) {
                        ForEach(TrackMapLayoutMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .disabled(model.isBuilding)
                    .accessibilityIdentifier("map-layout-picker")

                    if model.layoutMode == .customAxes {
                        Picker("X", selection: $model.xAxis) {
                            ForEach(TrackMapAxis.allCases) { axis in
                                Text(axis.displayName).tag(axis)
                            }
                        }
                        .frame(maxWidth: 170)
                        .accessibilityIdentifier("map-x-axis-picker")

                        Picker("Y", selection: $model.yAxis) {
                            ForEach(TrackMapAxis.allCases) { axis in
                                Text(axis.displayName).tag(axis)
                            }
                        }
                        .frame(maxWidth: 170)
                        .accessibilityIdentifier("map-y-axis-picker")
                    }

                    Spacer(minLength: 8)
                }

                HStack(spacing: 12) {
                    Picker("Colour by", selection: $model.colorMode) {
                        ForEach(TrackMapColorMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("map-color-mode-picker")

                    Button("Recompute Layout") {
                        model.recomputeLayout()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBuilding)
                    .help("Rebuilds the projection from every prepared track. Positions may shift.")
                    .accessibilityIdentifier("map-recompute-button")

                    if model.isBuilding {
                        ProgressView().controlSize(.small)
                    }

                    Spacer(minLength: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.summaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("map-status-message")

            if let variance = model.varianceSummary {
                // Stated plainly rather than hidden: two dimensions cannot hold
                // everything a 3072-dimension embedding knows, and a user deciding
                // how much to trust a cluster deserves the number.
                Text(variance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("map-variance-ratio")
            }

            if model.isLowConfidenceProjection {
                Label(
                    "Low projection confidence — dots that look close are not necessarily similar tracks. Check pairs with the compare panel before trusting a cluster.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("map-low-confidence-warning")
            }

            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Canvas

    private var colorsByKey: [String: NSColor] {
        TrackMapPalette.assignments(for: model.points.map(\.colorKey))
    }

    private var canvasCard: some View {
        ZStack {
            TrackMapCanvas(
                points: model.points,
                colorsByKey: colorsByKey,
                selectedTrackIDs: model.selectedTrackIDs,
                hoveredTrackID: model.hoveredTrackID,
                highlightedColorKey: model.highlightedColorKey,
                onHoverChanged: { model.hoveredTrackID = $0 },
                onSelectionChanged: { ids, additive in
                    model.updateSelection(ids, additive: additive)
                }
            )
            .accessibilityIdentifier("map-canvas")

            if model.points.isEmpty, !model.isBuilding {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { hoverCard }
        .overlay(alignment: .bottomTrailing) { legendCard }
        .overlay(alignment: .topTrailing) { accessibilitySummary }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.dots.scatter")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Nothing to plot yet.")
                .font(.headline)
            Text("The map needs at least two prepared tracks. Analyze some tracks in the Library first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("map-empty-state")
    }

    @ViewBuilder
    private var hoverCard: some View {
        if let hoveredTrackID = model.hoveredTrackID, let track = model.track(for: hoveredTrackID) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !track.artist.isEmpty {
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(Self.tempoAndKeyText(for: track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: 260, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var legendCard: some View {
        if !model.legend.isEmpty {
            let palette = colorsByKey
            VStack(alignment: .leading, spacing: 3) {
                // Long tails add noise rather than insight; the rest stay on the map,
                // just without their own legend row.
                ForEach(model.legend.prefix(10)) { entry in
                    Button {
                        model.toggleHighlight(entry.id)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(nsColor: palette[entry.id] ?? TrackMapPalette.unassignedColor))
                                .frame(width: 8, height: 8)
                            Text(entry.displayName).font(.caption).lineLimit(1)
                            Text("\(entry.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(model.highlightedColorKey == nil || model.highlightedColorKey == entry.id ? 1 : 0.4)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
            .accessibilityIdentifier("map-legend")
        }
    }

    // MARK: - Actions and comparison

    private var actionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(model.selectedTrackIDs.count) selected")
                        .font(.subheadline.weight(.semibold))

                    TextField("Folder name", text: $model.newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityIdentifier("map-folder-name-field")

                    Button("Create Folder from Selection") {
                        model.createFolderFromSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreateFolder)
                    .help("Groups the selected tracks as a Soria folder. Files are not moved.")
                    .accessibilityIdentifier("map-create-folder-button")

                    Button("Send Selection to Plan") {
                        model.sendSelectionToPlan()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canSendToPlan)
                    .help("Opens the Plan tab with these tracks in scope, where applying does move files.")
                    .accessibilityIdentifier("map-send-to-plan-button")

                    if !model.selectedTrackIDs.isEmpty {
                        Button("Clear") { model.clearSelection() }
                            .buttonStyle(.bordered)
                    }

                    Spacer(minLength: 8)
                }

                Text("Drag a box to select a region, click a dot to pick one, and hold Shift to add to the selection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !model.actionMessage.isEmpty {
                    Text(model.actionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("map-action-message")
                }

                comparisonPanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var comparisonPanel: some View {
        if let comparison = model.comparison {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Comparing two tracks").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Self.similarityText(comparison.cosineSimilarity))
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("map-compare-similarity")
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("").font(.caption)
                        Text(comparison.left.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(comparison.right.title).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    comparisonRow(
                        "Artist",
                        comparison.left.artist.isEmpty ? "—" : comparison.left.artist,
                        comparison.right.artist.isEmpty ? "—" : comparison.right.artist
                    )
                    comparisonRow(
                        "BPM",
                        Self.numberText(comparison.left.bpm),
                        Self.numberText(comparison.right.bpm)
                    )
                    comparisonRow(
                        "Key",
                        comparison.left.musicalKey ?? "—",
                        comparison.right.musicalKey ?? "—"
                    )
                    comparisonRow(
                        "Length",
                        Self.durationText(comparison.left.duration),
                        Self.durationText(comparison.right.duration)
                    )
                    comparisonRow(
                        "Genre",
                        comparison.left.genre.isEmpty ? "—" : comparison.left.genre,
                        comparison.right.genre.isEmpty ? "—" : comparison.right.genre
                    )
                    comparisonRow(
                        "Energy",
                        Self.numberText(comparison.leftRow?.energy, decimals: 2),
                        Self.numberText(comparison.rightRow?.energy, decimals: 2)
                    )
                    comparisonRow(
                        "Brightness",
                        Self.numberText(comparison.leftRow?.brightness, decimals: 2),
                        Self.numberText(comparison.rightRow?.brightness, decimals: 2)
                    )
                }
            }
            .accessibilityIdentifier("map-compare-card")
        } else if model.selectedTrackIDs.count > 2 {
            Text("Select exactly two dots to compare them side by side.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func comparisonRow(_ label: String, _ left: String, _ right: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(left).font(.caption).lineLimit(1)
            Text(right).font(.caption).lineLimit(1)
        }
    }

    /// Off-screen markers the UI tests read; a scatter plot has no stable text.
    private var accessibilitySummary: some View {
        VStack(spacing: 0) {
            AccessibilityMarker(identifier: "map-plotted-count", label: "\(model.plottedTrackCount)")
            AccessibilityMarker(identifier: "map-selection-count", label: "\(model.selectedTrackIDs.count)")
        }
        .frame(width: 1, height: 1, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    // MARK: - Formatting

    private static func similarityText(_ value: Double?) -> String {
        guard let value else { return "Similarity unavailable" }
        // Labelled as cosine because the app also has a 1/(1+distance) score
        // elsewhere that lives on a different scale.
        return String(format: "Cosine similarity %.3f", value)
    }

    private static func numberText(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }

    private static func durationText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func tempoAndKeyText(for track: Track) -> String {
        var parts: [String] = []
        if let bpm = track.bpm, bpm > 0 { parts.append(String(format: "%.0f BPM", bpm)) }
        if let key = track.musicalKey, !key.isEmpty { parts.append(key) }
        if parts.isEmpty { parts.append(durationText(track.duration)) }
        return parts.joined(separator: " · ")
    }
}

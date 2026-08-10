import SwiftUI

/// Build, review, and apply a folder plan.
///
/// The per-move checkbox is the point of the whole screen: the previous
/// folder-organization feature shipped a read-only preview, so the only choice
/// was all or nothing. Here every proposed move can be dropped before applying.
struct OrganizerPlanView: View {
    @ObservedObject var model: LibraryOrganizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            progressCard
            previewTable
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("organizer-plan-view")
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder Plan")
                            .font(.title3.weight(.semibold))
                        Text(model.summaryText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("organizer-summary")
                    }

                    Spacer(minLength: 12)

                    Picker("Scope", selection: $model.scope) {
                        ForEach(model.availableScopes) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    .disabled(model.isPlanning || model.isApplying)
                    .accessibilityIdentifier("organizer-scope-picker")
                }

                HStack(spacing: 8) {
                    TextField("Destination folder", text: $model.destinationRoot)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isPlanning || model.isApplying)
                        .accessibilityIdentifier("organizer-destination-field")
                        .onSubmit {
                            model.clearPlan(message: "Destination changed. Build a new organization preview.")
                        }

                    Button("Choose...") {
                        model.chooseDestinationRoot()
                    }
                    .disabled(model.isPlanning || model.isApplying)
                    .accessibilityIdentifier("organizer-choose-destination-button")
                }

                HStack(spacing: 8) {
                    Button("Build Preview") {
                        model.buildPlan()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canBuildPlan)
                    .accessibilityIdentifier("organizer-build-preview-button")

                    Button("Apply Selected") {
                        model.applyPlan()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canApplyPlan)
                    .accessibilityIdentifier("organizer-apply-button")

                    if model.plan != nil {
                        Button("Select All") { model.setAllMovesIncluded(true) }
                            .disabled(model.isApplying)
                        Button("Select None") { model.setAllMovesIncluded(false) }
                            .disabled(model.isApplying)
                    }

                    Button("Clear") {
                        model.clearPlan()
                    }
                    .disabled(model.isPlanning || model.isApplying)

                    Spacer(minLength: 8)
                }

                if !model.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("organizer-warnings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var progressCard: some View {
        if model.isPlanning || model.isApplying || !model.statusMessage.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.progress.stage.displayName)
                            .font(.headline)
                        Spacer()
                        Text(model.statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let fraction = model.progress.fraction, model.isApplying {
                        ProgressView(value: fraction)
                    } else if model.isPlanning || model.isApplying {
                        ProgressView()
                    }
                    if !model.progress.currentFileName.isEmpty {
                        Text(model.progress.currentFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var previewTable: some View {
        ZStack {
            Table(model.plan?.moves ?? []) {
                TableColumn("Use") { move in
                    Button {
                        model.toggleMoveIncluded(move.id)
                    } label: {
                        Image(
                            systemName: model.excludedMoveIDs.contains(move.id)
                                ? "square"
                                : "checkmark.square"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isApplying)
                    .accessibilityLabel(
                        model.excludedMoveIDs.contains(move.id) ? "Include move" : "Exclude move"
                    )
                }
                .width(44)

                TableColumn("Title") { move in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(move.title).lineLimit(1)
                        if !move.artist.isEmpty {
                            Text(move.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                TableColumn("Genre / Cluster") { move in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(move.genreName).lineLimit(1)
                        Text(move.clusterName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("Target") { move in
                    Text(move.targetPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(move.targetPath)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.plan == nil {
                emptyState(
                    icon: "folder.badge.gearshape",
                    title: "Build a preview to review proposed folder moves.",
                    detail: "Only prepared tracks are moved; tracks that still need analysis stay where they are."
                )
            } else if model.plan?.moves.isEmpty == true {
                emptyState(
                    icon: "checkmark.circle",
                    title: "No movable tracks in this preview.",
                    detail: skippedSummary
                )
            }
        }
        .overlay(alignment: .bottomLeading) { accessibilitySummary }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var skippedSummary: String {
        guard let plan = model.plan, !plan.skippedTracks.isEmpty else {
            return "Try a different scope or prepare more tracks first."
        }
        return "\(plan.skippedTracks.count) tracks were skipped."
    }

    /// Off-screen markers the UI tests read; the visible table has no stable text.
    private var accessibilitySummary: some View {
        VStack(spacing: 0) {
            AccessibilityMarker(
                identifier: "organizer-preview-move-count",
                label: "\(model.plan?.moveCount ?? 0)"
            )
            AccessibilityMarker(
                identifier: "organizer-preview-included-count",
                label: "\(model.includedMoveCount)"
            )
            AccessibilityMarker(
                identifier: "organizer-status-message",
                label: model.statusMessage
            )
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

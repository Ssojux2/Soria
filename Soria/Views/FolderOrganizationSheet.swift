import SwiftUI

struct FolderOrganizationSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            configuration
            statusArea
            previewArea
            footer
        }
        .padding(20)
        .frame(minWidth: 920, idealWidth: 980, minHeight: 640, idealHeight: 720)
        .accessibilityIdentifier("folder-organization-sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Organize Files")
                .font(.title2.weight(.semibold))

            Text("Preview folder moves before changing source files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var configuration: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text("Scope")
                    .foregroundStyle(.secondary)
                Picker("Scope", selection: $viewModel.folderOrganizationScope) {
                    ForEach(FolderOrganizationScope.allCases) { scope in
                        Text("\(scope.displayName) (\(viewModel.folderOrganizationTargetCount(for: scope)))")
                            .tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            GridRow {
                Text("Preset")
                    .foregroundStyle(.secondary)
                Picker("Preset", selection: $viewModel.folderOrganizationPreset) {
                    ForEach(FolderOrganizationPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
            }

            GridRow {
                Text("Intent")
                    .foregroundStyle(.secondary)
                TextField("warmup deep, vocal, peak time...", text: $viewModel.folderOrganizationPrompt)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("folder-organization-intent-field")
            }

            GridRow {
                Text("Destination")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(viewModel.folderOrganizationDestinationDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.chooseFolderOrganizationDestinationRoot()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                    .disabled(viewModel.isBuildingFolderOrganizationPlan || viewModel.isApplyingFolderOrganizationPlan)

                    Button {
                        viewModel.clearFolderOrganizationDestinationRoot()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Clear custom destination")
                    .disabled(
                        viewModel.folderOrganizationDestinationRoot.isEmpty ||
                        viewModel.isBuildingFolderOrganizationPlan ||
                        viewModel.isApplyingFolderOrganizationPlan
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if viewModel.isBuildingFolderOrganizationPlan {
            HStack(spacing: 10) {
                ProgressView()
                Text("Building organization preview...")
                    .foregroundStyle(.secondary)
            }
        } else if let progress = viewModel.folderOrganizationProgress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.message)
                    Spacer()
                    if progress.total > 0 {
                        Text("\(progress.completed) / \(progress.total)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction, total: 1)
                        .accessibilityIdentifier("folder-organization-progress")
                }
            }
        } else if !viewModel.folderOrganizationStatusMessage.isEmpty {
            Text(viewModel.folderOrganizationStatusMessage)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if let plan = viewModel.folderOrganizationPlan {
            VStack(alignment: .leading, spacing: 10) {
                planSummary(plan)

                if !plan.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Table(plan.moves) {
                    TableColumn("Track") { move in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(move.title)
                                .lineLimit(1)
                            if !move.artist.isEmpty {
                                Text(move.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    TableColumn("Bucket", value: \.bucket)
                    TableColumn("Action") { move in
                        Text(move.state.displayName)
                            .foregroundStyle(move.canMove ? .primary : .secondary)
                    }
                    TableColumn("Destination") { move in
                        Text(move.destinationPath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .frame(minHeight: 240)
                .accessibilityIdentifier("folder-organization-preview-table")
            }
        } else {
            ContentUnavailableView(
                "No Preview",
                systemImage: "folder.badge.gearshape",
                description: Text("Generate a preview to inspect every proposed move.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func planSummary(_ plan: FolderOrganizationPlan) -> some View {
        HStack(spacing: 14) {
            Label("\(plan.movableCount) ready", systemImage: "checkmark.circle")
            Label("\(plan.skippedCount) skipped", systemImage: "minus.circle")
            Label("\(plan.conflictCount) renamed", systemImage: "text.badge.checkmark")
            Spacer()
            Text("Target tracks: \(viewModel.folderOrganizationTargetCount)")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    private var footer: some View {
        HStack {
            if let result = viewModel.folderOrganizationResult {
                Text(result.summaryText)
                    .foregroundStyle(result.failedCount > 0 ? .red : .secondary)
                    .accessibilityIdentifier("folder-organization-result-summary")
            }

            Spacer()

            Button("Close") {
                viewModel.dismissFolderOrganizationSheetIfPossible()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.isBuildingFolderOrganizationPlan || viewModel.isApplyingFolderOrganizationPlan)

            Button {
                viewModel.buildFolderOrganizationPlan()
            } label: {
                Label("Preview", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(!viewModel.canBuildFolderOrganizationPlan)
            .accessibilityIdentifier("folder-organization-preview-button")

            Button {
                viewModel.applyFolderOrganizationPlan()
            } label: {
                Label("Apply Moves", systemImage: "arrow.right.doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canApplyFolderOrganizationPlan)
            .accessibilityIdentifier("folder-organization-apply-button")
        }
    }
}

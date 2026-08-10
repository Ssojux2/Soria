import SwiftUI

/// The individual Home cards.
///
/// Split from `HomeDashboardView` purely for file size. Every button here calls an
/// existing `AppViewModel` or child-model method and takes its enabled state from
/// an existing property — see the note on `HomeDashboardView`.

// MARK: - Shared chrome

/// One pipeline stage: a numbered title, a status line, and its actions.
struct HomeCard<Content: View>: View {
    let step: Int?
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                    Text(step.map { "\($0). \(title)" } ?? title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Actions wrap instead of clipping — these cards sit in a grid that can get narrow.
private struct HomeActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content(); Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }
}

private struct HomeCardSummary: View {
    let summary: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Setup

/// Only rendered when something is actually wrong; a healthy setup gets no card.
struct HomeSetupCard: View {
    let issues: [WorkspaceSetupIssue]
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Finish Setup", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.callout.weight(.semibold))
                        Text(issue.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HomeActionRow {
                    Button("Library Setup") { viewModel.openInitialSetup() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("home-library-setup-button")

                    Button("Choose Folder") { viewModel.addLibraryRoot() }
                        .accessibilityIdentifier("home-choose-folder-button")

                    Button("Scan Music Folders") { viewModel.scanMusicFolders() }
                        .accessibilityIdentifier("home-scan-button")

                    Button("Validate API Key") { viewModel.validateEmbeddingProfile() }
                        .disabled(
                            viewModel.validationStatus == .validating
                                || !viewModel.isSelectedEmbeddingProfileSupported
                        )
                        .accessibilityIdentifier("home-validate-button")

                    Button("Open Settings") { viewModel.selectedSection = .settings }
                        .accessibilityIdentifier("home-open-settings-button")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-setup-card")
    }
}

// MARK: - 1 Prepare

/// Reuses `preparationOverview`, the tested state machine that decides what the
/// next preparation step is. It had no UI at all before this card.
struct HomePrepareCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let overview = viewModel.preparationOverview

        HomeCard(step: 1, title: "Prepare", systemImage: "waveform.badge.magnifyingglass") {
            HomeCardSummary(summary: overview.title, detail: overview.message)

            if let progress = overview.progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress, total: 1)
                    Text("\(Int(progress * 100))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("home-prepare-progress")
            } else if overview.phase == .analyzing || overview.phase == .syncing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("home-prepare-progress")
            }

            HomeActionRow {
                if let primaryAction = overview.primaryAction {
                    Button(overview.primaryActionTitleOverride ?? viewModel.preparationActionTitle(primaryAction)) {
                        viewModel.performPreparationAction(primaryAction)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(overview.isPrimaryActionDisabled)
                    .accessibilityIdentifier("home-prepare-primary-button")
                }

                if let secondaryAction = overview.secondaryAction {
                    Button(viewModel.preparationActionTitle(secondaryAction)) {
                        viewModel.performPreparationAction(secondaryAction)
                    }
                    .accessibilityIdentifier("home-prepare-secondary-button")
                }

                if overview.isCancellable {
                    Button(viewModel.isCancellingAnalysis ? "Stopping..." : "Stop") {
                        viewModel.cancelAnalysis()
                    }
                    .tint(.red)
                    .disabled(viewModel.isCancellingAnalysis)
                    .accessibilityIdentifier("home-prepare-cancel-button")
                }

                Button("Open Library") { viewModel.selectedSection = .library }
                    .accessibilityIdentifier("home-open-library-button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-prepare-card")
    }
}

// MARK: - 2 Organize

struct HomeOrganizeCard: View {
    let card: WorkspaceOrganizeCard
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HomeCard(step: 2, title: "Organize", systemImage: "folder.badge.gearshape") {
            HomeCardSummary(summary: card.summary, detail: card.detail)

            if let latestOrganizationDate = card.latestOrganizationDate {
                Text("Last organized \(latestOrganizationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let trashSummary = card.trashSummary {
                Text(trashSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-trash-summary")
            }

            if !viewModel.organizer.exportMessage.isEmpty {
                Text(viewModel.organizer.exportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home-organize-message")
            }

            HomeActionRow {
                Button("Export Folders") { viewModel.organizer.exportCollections() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!card.canExportFolders)
                    .help("Sends every Soria folder to the selected DJ app without moving files.")
                    .accessibilityIdentifier("home-export-folders-button")

                Button("Build Plan") { viewModel.openOrganizer(mode: .plan) }
                    .accessibilityIdentifier("home-open-plan-button")

                Button("Open Map") { viewModel.openOrganizer(mode: .map) }
                    .accessibilityIdentifier("home-open-map-button")

                if card.canRestoreTrash {
                    Button("Restore All") {
                        Task { await viewModel.restoreAllQuarantinedTracks() }
                    }
                    .disabled(viewModel.isRestoringQuarantine)
                    .accessibilityIdentifier("home-restore-trash-button")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-organize-card")
    }
}

// MARK: - 3 Mix

struct HomeMixCard: View {
    let card: WorkspaceMixCard
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HomeCard(step: 3, title: "Mix", systemImage: "sparkles") {
            HomeCardSummary(summary: card.summary, detail: card.detail)

            TextField("Describe the sound or transition you want", text: $viewModel.recommendationQueryText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard card.canGenerate else { return }
                    viewModel.generateRecommendations()
                }
                .accessibilityIdentifier("home-mix-query-field")

            if let generatedSummary = card.generatedSummary {
                Text(generatedSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-mix-generated-summary")
            }

            if !viewModel.recommendationStatusMessage.isEmpty {
                Text(viewModel.recommendationStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home-mix-status-message")
            }

            HomeActionRow {
                Button(viewModel.recommendationGenerateButtonTitle) {
                    viewModel.generateRecommendations()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!card.canGenerate)
                .accessibilityIdentifier("home-mix-generate-button")

                Button("Open Mix Assistant") { viewModel.openMixAssistant(mode: .buildMixset) }
                    .accessibilityIdentifier("home-open-mix-assistant-button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-mix-card")
    }
}

// MARK: - 4 Export

struct HomeExportCard: View {
    let card: WorkspaceExportCard
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HomeCard(step: 4, title: "Export", systemImage: "square.and.arrow.up") {
            HomeCardSummary(summary: card.summary, detail: card.detail)

            Picker("Target", selection: $viewModel.selectedExportTarget) {
                ForEach(ExportTarget.allCases) { target in
                    Text(target.shortLabel).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("home-export-target-picker")

            if !viewModel.exportMessage.isEmpty {
                Text(viewModel.exportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home-export-message")
            }

            ForEach(Array(viewModel.exportWarnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                Text("• \(warning)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HomeActionRow {
                Button(viewModel.selectedExportTarget == .seratoCrate ? "Create Serato Crate" : "Export Playlist") {
                    viewModel.exportPlaylist()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!card.canExport)
                .accessibilityIdentifier("home-export-button")

                Button("Open Exports") { viewModel.selectedSection = .exports }
                    .accessibilityIdentifier("home-open-exports-button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-export-card")
    }
}

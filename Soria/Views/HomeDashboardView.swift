import SwiftUI

/// The one screen that drives the whole pipeline.
///
/// Soria's features were spread across five sidebar sections, but the thing almost
/// every action operates on — the track selection — only lives in Library. That
/// meant hopping panes to prepare, organize, mix, or export, losing the table each
/// time. Home puts the four stages side by side with their live counts and runs
/// whatever does not need a full-width table right here.
///
/// The rule this screen lives by: it renders state and calls existing methods. It
/// never decides for itself whether an action is available — those flags come from
/// the same properties the owning pane uses (see
/// `AppViewModel.workspaceDashboardContext`). Anything that needs room for a table
/// or a canvas (the organization plan, the similarity map, curated mix results)
/// gets a button that navigates instead of a cramped copy.
struct HomeDashboardView: View {
    @ObservedObject var viewModel: AppViewModel

    private static let wideLayoutMinimumWidth: CGFloat = 900

    var body: some View {
        // Built once per render and threaded down. `selectionReadiness` walks the
        // whole track list, so rebuilding the context for each marker below would
        // scan a five-thousand-track library several times per frame.
        let context = viewModel.workspaceDashboardContext
        let dashboard = WorkspaceDashboardState.make(from: context)

        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HomeHeaderView(dashboard: dashboard, viewModel: viewModel)

                    if !dashboard.isSetupHealthy {
                        HomeSetupCard(issues: dashboard.setupIssues, viewModel: viewModel)
                    }

                    LazyVGrid(columns: columns(for: proxy.size.width), alignment: .leading, spacing: 16) {
                        HomePrepareCard(viewModel: viewModel)
                        HomeOrganizeCard(card: dashboard.organize, viewModel: viewModel)
                        HomeMixCard(card: dashboard.mix, viewModel: viewModel)
                        HomeExportCard(card: dashboard.export, viewModel: viewModel)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            viewModel.refreshWorkspaceSnapshot()
        }
        .overlay(alignment: .bottomLeading) {
            accessibilitySummary(context: context, dashboard: dashboard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-dashboard-view")
    }

    /// Two columns when there is room, one when the window is narrow. The cards
    /// carry paragraphs of status text, so squeezing two into a small window makes
    /// them unreadable rather than compact.
    private func columns(for width: CGFloat) -> [GridItem] {
        let count = width >= Self.wideLayoutMinimumWidth ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }

    /// The cards are mostly buttons and formatted numbers, so UI tests read the
    /// counts from markers instead of trying to parse a sentence.
    private func accessibilitySummary(
        context: WorkspaceDashboardContext,
        dashboard: WorkspaceDashboardState
    ) -> some View {
        VStack(spacing: 0) {
            AccessibilityMarker(identifier: "home-ready-count", label: "\(context.readyTrackCount)")
            AccessibilityMarker(identifier: "home-needs-prep-count", label: "\(context.needsPreparationCount)")
            AccessibilityMarker(identifier: "home-queue-count", label: "\(context.playlistQueueCount)")
            AccessibilityMarker(identifier: "home-setup-issue-count", label: "\(dashboard.setupIssues.count)")
        }
        .frame(width: 1, height: 1, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

private struct HomeHeaderView: View {
    let dashboard: WorkspaceDashboardState
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dashboard.headline)
                .font(.title2.bold())
                .accessibilityIdentifier("home-headline")

            Text(dashboard.readinessSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home-readiness-summary")

            HStack(spacing: 6) {
                Image(systemName: viewModel.validationStatus.isValidated ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(viewModel.validationStatus.isValidated ? .green : .secondary)
                Text(dashboard.profileSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

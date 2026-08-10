import SwiftUI

/// Actions and status that follow you into every pane.
///
/// Preparation is the long-running job in this app and it used to be invisible the
/// moment you left the Library pane — you could not see how far along it was or
/// stop it without navigating back. The toolbar keeps the current step, its
/// progress, and the stop button reachable from wherever you are working.
///
/// Deliberately three items. A macOS toolbar collapses into an overflow menu on a
/// narrow window, and the first thing worth losing is the read-only status text,
/// so that one goes last.
struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var viewModel: AppViewModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            primaryAction
        }

        ToolbarItem(placement: .automatic) {
            Button {
                viewModel.syncLibraries()
            } label: {
                Label("Sync Library", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Rescans music folders and refreshes Serato and rekordbox metadata.")
            .accessibilityIdentifier("toolbar-sync-button")
        }

        ToolbarItem(placement: .automatic) {
            statusReadout
        }
    }

    /// Mirrors the Home Prepare card: the same `preparationOverview` decides both,
    /// so the toolbar can never offer a step the card disagrees with.
    @ViewBuilder
    private var primaryAction: some View {
        let overview = viewModel.preparationOverview

        if overview.isCancellable {
            Button(role: .destructive) {
                viewModel.cancelAnalysis()
            } label: {
                Label(viewModel.isCancellingAnalysis ? "Stopping..." : "Stop", systemImage: "stop.fill")
            }
            .disabled(viewModel.isCancellingAnalysis)
            .accessibilityIdentifier("toolbar-primary-button")
        } else if let primaryAction = overview.primaryAction {
            Button {
                viewModel.performPreparationAction(primaryAction)
            } label: {
                Label(
                    overview.primaryActionTitleOverride ?? viewModel.preparationActionTitle(primaryAction),
                    systemImage: "play.fill"
                )
            }
            .disabled(overview.isPrimaryActionDisabled)
            .accessibilityIdentifier("toolbar-primary-button")
        }
    }

    /// Reads the two counts straight off the view model rather than building a
    /// `WorkspaceDashboardContext`. Both are O(1), while assembling the full context
    /// walks the track list — and this toolbar redraws on every pane, not just Home.
    private var statusReadout: some View {
        Button {
            viewModel.selectedSection = .home
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.validationStatus.isValidated ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)

                Text(
                    "\(WorkspaceDashboardState.formatted(viewModel.activeEmbeddingTrackCount))"
                        + " / \(WorkspaceDashboardState.formatted(viewModel.tracks.count)) ready"
                )
                .font(.callout.monospacedDigit())
            }
        }
        .buttonStyle(.plain)
        .help("Prepared tracks out of the whole library. Opens Home.")
        .accessibilityIdentifier("toolbar-status-readout")
    }
}

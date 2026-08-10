import SwiftUI

/// Home for organizing the local library: building a folder plan, and reviewing
/// what was set aside in the Soria Trash.
///
/// A pane rather than a sheet because the workflow is multi-step — scope, preview,
/// per-move opt-out, apply, review, export — and needs room for a long table.
struct OrganizerView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $viewModel.organizerMode) {
                ForEach(OrganizerMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .accessibilityIdentifier("organizer-mode-picker")

            switch viewModel.organizerMode {
            case .plan:
                planPlaceholder
            case .quarantine:
                QuarantineReviewView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("organizer-view")
    }

    // Replaced by the plan builder in the organization-engine phase.
    private var planPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folder Plan")
                .font(.headline)
            Text("Automatic folder organization is not wired up yet. Use Soria Trash to set unwanted tracks aside in the meantime.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("organizer-plan-placeholder")
    }
}

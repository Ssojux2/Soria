import SwiftUI

/// Home for organizing the local library: building a folder plan, seeing the library
/// as a similarity map, and reviewing what was set aside in the Soria Trash.
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
                OrganizerPlanView(model: viewModel.organizer)
            case .map:
                TrackMapView(model: viewModel.trackMap)
            case .quarantine:
                QuarantineReviewView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("organizer-view")
    }
}

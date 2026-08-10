import SwiftUI

/// Review, restore, or permanently delete tracks moved into the Soria Trash.
///
/// The whole point of a Soria-managed folder over the system Trash is that this
/// list exists: the user can see exactly what they culled and put any of it back.
struct QuarantineReviewView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if viewModel.quarantineRows.isEmpty {
                emptyState
            } else {
                quarantineTable
            }

            if !viewModel.quarantineStatusMessage.isEmpty {
                Text(viewModel.quarantineStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quarantine-status-message")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("quarantine-view")
        .onAppear {
            viewModel.refreshQuarantineRows()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Soria Trash")
                    .font(.headline)
                Text(viewModel.quarantineCountText + " set aside. Files stay on the same drive until you delete them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("quarantine-count")
            }

            Spacer(minLength: 12)

            actionButtons
        }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { restoreSelectedButton; restoreAllButton; deletePermanentlyButton }
            VStack(alignment: .trailing, spacing: 8) {
                restoreSelectedButton
                restoreAllButton
                deletePermanentlyButton
            }
        }
    }

    private var restoreSelectedButton: some View {
        Button("Restore Selected") {
            Task { await viewModel.restoreSelectedQuarantinedTracks() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canRestoreSelectedQuarantine)
        .accessibilityIdentifier("quarantine-restore-selected-button")
    }

    private var restoreAllButton: some View {
        Button("Restore All") {
            Task { await viewModel.restoreAllQuarantinedTracks() }
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.canRestoreAllQuarantine)
        .accessibilityIdentifier("quarantine-restore-all-button")
    }

    private var deletePermanentlyButton: some View {
        Button("Delete Permanently") {
            Task { await viewModel.purgeSelectedQuarantinedTracks() }
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.canRestoreSelectedQuarantine)
        .help("Moves the selected files to the system Trash. You can still recover them there with Put Back.")
        .accessibilityIdentifier("quarantine-delete-button")
    }

    private var emptyState: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing in the Soria Trash")
                    .font(.subheadline.weight(.semibold))
                Text("Select tracks in the Library and choose Move to Soria Trash to set them aside without deleting them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("quarantine-empty-state")
    }

    private var quarantineTable: some View {
        Table(viewModel.quarantineRows, selection: $viewModel.selectedQuarantineTrackIDs) {
            TableColumn("Title") { row in
                Text(row.title).lineLimit(1)
            }
            TableColumn("Artist") { row in
                Text(row.artist).lineLimit(1).foregroundStyle(.secondary)
            }
            TableColumn("Came From") { row in
                Text(row.originalFolderName)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(row.record.originalPath)
            }
            TableColumn("Status") { row in
                Text(row.statusText)
                    .foregroundStyle(row.fileExists ? .secondary : Color.orange)
            }
        }
        .accessibilityIdentifier("quarantine-table")
    }
}

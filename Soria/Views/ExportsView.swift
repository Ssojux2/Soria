import SwiftUI

struct ExportsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Exports")
                    .font(.title2.bold())

                Text("Playlist items ready: \(viewModel.playlistTracks.count)")
                    .foregroundStyle(.secondary)

                Picker("Target", selection: $viewModel.selectedExportTarget) {
                    ForEach(ExportTarget.allCases) { target in
                        Text(target.shortLabel).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                GroupBox("Selected Target") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.selectedExportTarget.displayName)
                            .font(.headline)
                        Text(viewModel.selectedExportTarget.helperText)
                            .foregroundStyle(.secondary)
                        Text(viewModel.selectedExportTargetStatusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(viewModel.selectedExportTarget == .seratoCrate ? "Create Serato Crate" : "Export Playlist") {
                    viewModel.exportPlaylist()
                }
                .disabled(!viewModel.canExportPlaylist)

                if !viewModel.exportMessage.isEmpty {
                    Text(viewModel.exportMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.exportDestinationDescription.isEmpty {
                    Text(viewModel.exportDestinationDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Detected Vendor Paths") {
                    VStack(alignment: .leading, spacing: 8) {
                        vendorPathRow(
                            label: "rekordbox 6/7",
                            value: viewModel.detectedVendorTargets.rekordboxLibraryDirectory
                                ?? viewModel.detectedVendorTargets.rekordboxSettingsPath
                        )
                        vendorPathRow(
                            label: "Serato _Serato_",
                            value: viewModel.detectedVendorTargets.seratoCratesRoot
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !viewModel.exportWarnings.isEmpty {
                    GroupBox("Warnings") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(viewModel.exportWarnings.enumerated()), id: \.offset) { _, warning in
                                Text("• \(warning)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("exports-info-view")
    }

    @ViewBuilder
    private func vendorPathRow(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.headline)
            Text(value ?? "Not detected")
                .font(.footnote)
                .foregroundStyle(value == nil ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}

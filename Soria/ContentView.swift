import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(SidebarSection.allCases) { section in
                    Button {
                        viewModel.selectedSection = section
                    } label: {
                        HStack {
                            Label(section.rawValue, systemImage: icon(for: section))
                            Spacer()
                            if section == viewModel.selectedSection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } content: {
            Group {
                switch viewModel.selectedSection {
                case .library:
                    LibraryView(viewModel: viewModel)
                case .scanJobs:
                    ScanJobsView(viewModel: viewModel)
                case .analysis:
                    AnalysisView(viewModel: viewModel)
                case .recommendations:
                    RecommendationsView(viewModel: viewModel)
                case .exports:
                    ExportsView(viewModel: viewModel)
                case .settings:
                    SettingsView(viewModel: viewModel)
                }
            }
            .navigationTitle(viewModel.selectedSection.rawValue)
        } detail: {
            TrackDetailView(viewModel: viewModel)
        }
        .frame(minWidth: 1280, minHeight: 800)
        .sheet(isPresented: $viewModel.isShowingInitialSetupSheet) {
            InitialSetupSheet(viewModel: viewModel)
        }
    }

    private func icon(for section: SidebarSection) -> String {
        switch section {
        case .library:
            return "music.note.list"
        case .scanJobs:
            return "arrow.triangle.2.circlepath"
        case .analysis:
            return "waveform.path.ecg"
        case .recommendations:
            return "sparkles"
        case .exports:
            return "square.and.arrow.up"
        case .settings:
            return "gearshape"
        }
    }
}

private struct InitialSetupSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose Your Music Folder")
                .font(.title2.bold())

            Text("Pick the folder that contains the tracks you want Soria to scan. You can optionally import existing rekordbox XML and Serato CSV metadata during the same setup flow.")
                .foregroundStyle(.secondary)

            GroupBox("Music Folder") {
                VStack(alignment: .leading, spacing: 10) {
                    pathLine(
                        title: "Selected Folder",
                        value: viewModel.initialSetupLibraryRoot,
                        placeholder: "No music folder selected yet."
                    )

                    HStack {
                        Button("Browse Folder") {
                            viewModel.chooseInitialSetupLibraryRoot()
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Optional DJ Metadata") {
                VStack(alignment: .leading, spacing: 14) {
                    metadataRow(
                        title: "rekordbox XML",
                        value: viewModel.initialSetupRekordboxPath,
                        placeholder: "Optional. Choose a rekordbox XML export.",
                        browseAction: viewModel.chooseInitialSetupRekordboxFile,
                        clearAction: { viewModel.clearInitialSetupMetadataPath(for: .rekordbox) }
                    )

                    metadataRow(
                        title: "Serato CSV",
                        value: viewModel.initialSetupSeratoPath,
                        placeholder: "Optional. Choose a Serato CSV export.",
                        browseAction: viewModel.chooseInitialSetupSeratoFile,
                        clearAction: { viewModel.clearInitialSetupMetadataPath(for: .serato) }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.isRunningInitialSetup || !viewModel.initialSetupStatusMessage.isEmpty {
                GroupBox("Setup Progress") {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.scanProgress.isRunning || viewModel.isRunningInitialSetup {
                            ProgressView(
                                value: Double(viewModel.scanProgress.scannedFiles),
                                total: Double(max(viewModel.scanProgress.totalFiles, 1))
                            )
                            Text("Scanned \(viewModel.scanProgress.scannedFiles) / \(viewModel.scanProgress.totalFiles)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if !viewModel.scanProgress.currentFile.isEmpty {
                                Text(viewModel.scanProgress.currentFile)
                                    .font(.footnote)
                                    .lineLimit(1)
                            }
                        }

                        if !viewModel.initialSetupStatusMessage.isEmpty {
                            Text(viewModel.initialSetupStatusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Button("Not Now") {
                    viewModel.dismissInitialSetup()
                }
                .disabled(viewModel.isRunningInitialSetup)

                Spacer()

                Button("Start Setup") {
                    viewModel.completeInitialSetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.initialSetupLibraryRoot.isEmpty || viewModel.isRunningInitialSetup)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 430)
    }

    private func metadataRow(
        title: String,
        value: String,
        placeholder: String,
        browseAction: @escaping () -> Void,
        clearAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            pathLine(title: title, value: value, placeholder: placeholder)

            HStack {
                Button("Browse") {
                    browseAction()
                }
                .disabled(viewModel.isRunningInitialSetup)

                if !value.isEmpty {
                    Button("Clear") {
                        clearAction()
                    }
                    .disabled(viewModel.isRunningInitialSetup)
                }

                Spacer()
            }
        }
    }

    private func pathLine(title: String, value: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)

            Text(value.isEmpty ? placeholder : value)
                .font(.footnote)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

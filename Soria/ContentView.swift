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
                    .accessibilityIdentifier("sidebar-\(section.rawValue.lowercased())")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VSplitView {
                selectedInfoPane
                    .frame(minHeight: selectedInfoPaneMinHeight, idealHeight: selectedInfoPaneIdealHeight)
                    .layoutPriority(1)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("right-pane-info")

                LibraryView(viewModel: viewModel)
                    .frame(minHeight: 340, idealHeight: 420)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("right-pane-library")
            }
            .navigationTitle(viewModel.selectedSection.rawValue)
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
        case .search:
            return "magnifyingglass"
        case .recommendations:
            return "sparkles"
        case .exports:
            return "square.and.arrow.up"
        case .settings:
            return "gearshape"
        }
    }

    private var selectedInfoPaneMinHeight: CGFloat {
        switch viewModel.selectedSection {
        case .search:
            return 380
        case .recommendations:
            return 460
        default:
            return 260
        }
    }

    private var selectedInfoPaneIdealHeight: CGFloat {
        switch viewModel.selectedSection {
        case .search:
            return 440
        case .recommendations:
            return 560
        default:
            return 320
        }
    }

    @ViewBuilder
    private var selectedInfoPane: some View {
        switch viewModel.selectedSection {
        case .library:
            TrackDetailView(viewModel: viewModel)
        case .search:
            SearchView(viewModel: viewModel)
        case .recommendations:
            RecommendationsView(viewModel: viewModel)
        case .exports:
            ExportsView(viewModel: viewModel)
        case .settings:
            SettingsView(viewModel: viewModel)
        }
    }
}

private struct InitialSetupSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Your DJ Libraries")
                .font(.title2.bold())

            Text("Soria now starts from the libraries that Serato and rekordbox already know about. Use manual folder scanning only as a fallback when a DJ library is unavailable.")
                .foregroundStyle(.secondary)

            GroupBox("Auto-Detected DJ Libraries") {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.nativeLibrarySources.isEmpty {
                        Text("No DJ libraries detected yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.nativeLibrarySources) { source in
                            sourceRow(source)
                        }
                    }

                    HStack {
                        Button("Refresh Detection") {
                            viewModel.refreshLibrarySourceDetection()
                        }
                        .disabled(viewModel.isRunningInitialSetup)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Manual Folder Fallback") {
                VStack(alignment: .leading, spacing: 14) {
                    pathLine(
                        title: "Selected Folder",
                        value: viewModel.initialSetupLibraryRoot,
                        placeholder: "Optional. Choose one folder if you want a manual fallback scan."
                    )

                    HStack {
                        Button("Browse Folder") {
                            viewModel.chooseInitialSetupLibraryRoot()
                        }
                        .disabled(viewModel.isRunningInitialSetup)

                        if !viewModel.initialSetupLibraryRoot.isEmpty {
                            Button("Clear") {
                                viewModel.clearInitialSetupLibraryRoot()
                            }
                            .disabled(viewModel.isRunningInitialSetup)
                        }

                        Spacer()
                    }
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
                .disabled(!canStartSetup || viewModel.isRunningInitialSetup)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 500)
    }

    private var canStartSetup: Bool {
        viewModel.nativeLibrarySources.contains { $0.enabled && $0.resolvedPath != nil } ||
        !viewModel.initialSetupLibraryRoot.isEmpty
    }

    private func sourceRow(_ source: LibrarySourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(source.kind.displayName, systemImage: source.kind.iconName)
                    .font(.headline)
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { source.enabled },
                        set: { viewModel.setLibrarySourceEnabled(source.kind, enabled: $0) }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(source.resolvedPath == nil || viewModel.isRunningInitialSetup)
            }

            HStack {
                Text(source.status.displayText)
                    .font(.footnote.weight(.semibold))
                if let lastSyncAt = source.lastSyncAt {
                    Text("Last sync \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text(source.resolvedPath ?? "Not detected on this Mac.")
                .font(.footnote)
                .foregroundStyle(source.resolvedPath == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)

            if let lastError = source.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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

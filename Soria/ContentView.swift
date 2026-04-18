import AppKit
import CoreGraphics
import SwiftUI

struct ContentView: View {
    private static let mainWindowAutosaveName = "SoriaMainWindow"

    @StateObject private var viewModel = AppViewModel()
    @State private var hasScheduledMainWindowRecovery = false

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
                    .accessibilityIdentifier(
                        "sidebar-\(section.rawValue.replacingOccurrences(of: " ", with: "-").lowercased())"
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            selectedDetailPane
            .navigationTitle(viewModel.selectedSection.rawValue)
            .inspector(isPresented: scopeInspectorBinding) {
                if let target = viewModel.activeScopeInspectorTarget {
                    ScopeFilterInspectorView(viewModel: viewModel, target: target)
                        .inspectorColumnWidth(min: 280, ideal: 360, max: 520)
                } else {
                    EmptyView()
                }
            }
        }
        .frame(minWidth: 1280, minHeight: 800)
        .background(
            WindowAccessor { window in
                recoverMainWindowIfNeeded(window)
            }
        )
        .sheet(isPresented: $viewModel.isShowingInitialSetupSheet) {
            InitialSetupSheet(viewModel: viewModel)
        }
        .sheet(isPresented: librarySyncSheetBinding) {
            LibrarySyncSheet(viewModel: viewModel)
                .interactiveDismissDisabled(viewModel.librarySyncPresentationState?.phase == .running)
        }
    }

    private var scopeInspectorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isScopeInspectorPresented },
            set: { isPresented in
                if isPresented {
                    viewModel.isScopeInspectorPresented = true
                } else {
                    viewModel.closeScopeInspector()
                }
            }
        )
    }

    private var librarySyncSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isLibrarySyncSheetPresented },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissLibrarySyncSheetIfPossible()
                }
            }
        )
    }

    private func recoverMainWindowIfNeeded(_ window: NSWindow) {
        guard !hasScheduledMainWindowRecovery else { return }

        hasScheduledMainWindowRecovery = true
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        _ = window.setFrameUsingName(Self.mainWindowAutosaveName, force: false)
        window.isRestorable = false
        window.collectionBehavior.insert(.moveToActiveSpace)

        for delay in [0.0, 0.35, 1.0, 2.0, 4.0, 6.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                recoverMainWindowFrame(window)
            }
        }
    }

    private func recoverMainWindowFrame(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let currentFrame = window.frame
        if overlapsVisibleScreen(currentFrame) {
            return
        }

        guard let targetScreen = fallbackScreen() else { return }
        let targetFrame = targetScreen.visibleFrame

        let width = min(max(currentFrame.width, 1280), targetFrame.width)
        let height = min(max(currentFrame.height, 800), targetFrame.height)
        let origin = NSPoint(
            x: targetFrame.midX - (width / 2),
            y: targetFrame.midY - (height / 2)
        )
        let adjustedOrigin = NSPoint(
            x: max(targetFrame.minX, min(origin.x, targetFrame.maxX - width)),
            y: max(targetFrame.minY, min(origin.y, targetFrame.maxY - height))
        )
        let recoveredFrame = NSRect(origin: adjustedOrigin, size: NSSize(width: width, height: height)).integral

        window.setFrame(recoveredFrame, display: true, animate: false)
        window.orderFrontRegardless()
    }

    private func overlapsVisibleScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let overlap = frame.intersection(screen.visibleFrame)
            return !overlap.isNull && overlap.width >= 180 && overlap.height >= 180
        }
    }

    private func fallbackScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()

        return NSScreen.screens.first {
            guard let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(screenNumber.uint32Value) == mainDisplayID
        } ?? NSScreen.screens.first
    }

    private func icon(for section: SidebarSection) -> String {
        switch section {
        case .library:
            return "music.note.list"
        case .mixAssistant:
            return "sparkles"
        case .exports:
            return "square.and.arrow.up"
        case .settings:
            return "gearshape"
        }
    }

    @ViewBuilder
    private var selectedDetailPane: some View {
        switch viewModel.selectedSection {
        case .library:
            LibraryView(viewModel: viewModel)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("right-pane-library")
        case .mixAssistant:
            MixAssistantView(viewModel: viewModel)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("right-pane-mix-assistant")
        case .exports:
            VSplitView {
                ZStack {
                    ExportsView(viewModel: viewModel)
                }
                .frame(minHeight: 240, idealHeight: 320, maxHeight: 360)
                .clipped()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("right-pane-info")

                ZStack {
                    ExportPlaylistQueueView(viewModel: viewModel)
                }
                .frame(minHeight: 420, idealHeight: 560, maxHeight: .infinity)
                .layoutPriority(1)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("right-pane-playlist-queue")
            }
        case .settings:
            SettingsView(viewModel: viewModel)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("right-pane-settings")
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            onResolveWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            onResolveWindow(window)
        }
    }
}

private struct InitialSetupSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheetTitle)
                .font(.title2.bold())

            Text(sheetDescription)
                .foregroundStyle(.secondary)

            GroupBox("Analysis Access") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Soria validates the active embedding profile before track preparation can start.")
                        .foregroundStyle(.secondary)

                    if viewModel.embeddingProfile.requiresAPIKey {
                        Text("Google AI API Key")
                            .font(.headline)
                        SecureField("Paste your Google AI API key", text: $viewModel.googleAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isRunningInitialSetup)
                            .accessibilityIdentifier("initial-setup-google-api-key-field")
                            .onSubmit {
                                if canStartSetup {
                                    viewModel.completeInitialSetup()
                                }
                            }

                        if viewModel.initialSetupNeedsGoogleAIAPIKey {
                            Text("Enter your Google AI API key so Soria can validate \(viewModel.embeddingProfile.displayName).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(viewModel.validationStatus.summaryText)
                        .font(.footnote)
                        .foregroundStyle(validationStatusColor)

                    Text("Active model: \(viewModel.embeddingProfile.displayName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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

            GroupBox("Music Folders") {
                VStack(alignment: .leading, spacing: 14) {
                    pathLine(
                        title: "Selected Folder",
                        value: viewModel.initialSetupLibraryRoot,
                        placeholder: "Choose one local music folder so Soria can build the authoritative library."
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
                        if viewModel.scanProgress.isRunning {
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
                        } else if viewModel.isRunningInitialSetup {
                            ProgressView()
                                .controlSize(.small)
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

                Button(primaryButtonTitle) {
                    viewModel.completeInitialSetup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStartSetup || viewModel.isRunningInitialSetup)
                .accessibilityIdentifier("initial-setup-primary-button")
            }
            .overlay(alignment: .topLeading) {
                AccessibilityMarker(
                    identifier: "initial-setup-primary-button-marker",
                    label: "Initial Setup Primary Button"
                )
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 500)
        .accessibilityIdentifier("initial-setup-sheet")
    }

    private var canStartSetup: Bool {
        let hasLibrarySelection =
            !viewModel.initialSetupLibraryRoot.isEmpty || !viewModel.libraryRoots.isEmpty
        return !viewModel.initialSetupNeedsGoogleAIAPIKey &&
            (!viewModel.initialSetupRequiresLibrarySelection || hasLibrarySelection)
    }

    private var sheetTitle: String {
        if viewModel.initialSetupNeedsGoogleAIAPIKey && viewModel.initialSetupRequiresLibrarySelection {
            return "Finish Setup"
        }
        if viewModel.initialSetupNeedsGoogleAIAPIKey {
            return "Connect Google AI"
        }
        return "Connect Your Music Library"
    }

    private var sheetDescription: String {
        if viewModel.initialSetupNeedsGoogleAIAPIKey && viewModel.initialSetupRequiresLibrarySelection {
            return "Add your Google AI API key, then choose the local music folders Soria should scan."
        }
        if viewModel.initialSetupNeedsGoogleAIAPIKey {
            return "Add your Google AI API key so Soria can validate the active embedding profile as soon as the app starts."
        }
        return "Soria now treats your local music folders as the source of truth. Serato and rekordbox are used only to enrich those tracks with DJ metadata."
    }

    private var primaryButtonTitle: String {
        let hasLibrarySelection =
            !viewModel.initialSetupLibraryRoot.isEmpty || !viewModel.libraryRoots.isEmpty

        if !viewModel.validationStatus.isValidated && hasLibrarySelection {
            return "Validate and Start Setup"
        }
        if !viewModel.validationStatus.isValidated {
            return "Save and Validate"
        }
        if hasLibrarySelection {
            return "Start Setup"
        }
        return "Done"
    }

    private var validationStatusColor: Color {
        if viewModel.validationStatus.isValidated {
            return .green
        }
        if case .failed = viewModel.validationStatus {
            return .red
        }
        return .secondary
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

private struct LibrarySyncSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let state = viewModel.librarySyncPresentationState

        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(state?.title ?? "Refreshing Library")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(sheetSubtitle(for: state))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let state, !state.sourceNames.isEmpty {
                Text(state.sourceNames.joined(separator: ", "))
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            if state?.phase == .running {
                if let progress = state?.progress {
                    ProgressView(value: progress, total: 1)
                } else if state?.isIndeterminate == true {
                    ProgressView()
                }
            }

            VStack(spacing: 8) {
                Text(state?.message ?? "Preparing library update.")
                    .font(.body)
                    .foregroundStyle(state?.phase == .failed ? .red : .primary)
                    .multilineTextAlignment(.center)

                if let stats = state?.stats {
                    Text(progressSummary(for: stats))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

            if state?.phase == .failed {
                Button("Close") {
                    viewModel.dismissLibrarySyncSheetIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library-sync-close-button")
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 540)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .topLeading) {
            if state?.phase == .running {
                AccessibilityMarker(
                    identifier: "library-sync-progress",
                    label: "Library Sync Progress"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-sync-sheet")
    }

    private func sheetSubtitle(for state: LibrarySyncPresentationState?) -> String {
        if state?.phase == .failed {
            return "Library sync needs attention before you continue."
        }
        return "Analysis options will appear here when library sync finishes."
    }

    private func progressSummary(for stats: ScanJobProgress) -> String {
        let scannedTotal = stats.totalFiles > 0 ? "\(stats.scannedFiles) / \(stats.totalFiles)" : "\(stats.scannedFiles)"
        return "Scanned \(scannedTotal) • Indexed \(stats.indexedFiles) • Skipped \(stats.skippedFiles)"
    }
}

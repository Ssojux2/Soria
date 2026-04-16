import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.title2.bold())

                GroupBox("Analysis Worker") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Embedding Profile")
                            .font(.headline)
                        Picker("Embedding Profile", selection: $viewModel.embeddingProfile) {
                            ForEach(EmbeddingProfile.all, id: \.id) { profile in
                                Text(profile.displayName)
                                    .tag(profile)
                                    .disabled(!(viewModel.workerProfileStatuses[profile.id]?.supported ?? true))
                            }
                        }
                        .pickerStyle(.menu)

                        Text("Active model: \(viewModel.embeddingProfile.modelName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if viewModel.embeddingProfile == .googleGeminiEmbedding2Preview {
                            Text("Experimental preview profile. Prefer gemini-embedding-001 for stable day-to-day analysis.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let dependencyMessage = viewModel.selectedEmbeddingProfileDependencyMessage {
                            Text(dependencyMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Text("Validation")
                            .font(.headline)
                        Text(viewModel.validationStatus.summaryText)
                            .font(.footnote)
                            .foregroundStyle(viewModel.validationStatus.isValidated ? .green : .secondary)

                        Text("Google AI API Key")
                            .font(.headline)
                        SecureField("Paste your Google AI API key", text: $viewModel.googleAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!viewModel.embeddingProfile.requiresAPIKey)

                        if !viewModel.embeddingProfile.requiresAPIKey {
                            Text("This profile does not require a Google AI API key, but it still needs explicit validation.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Text("Python Executable")
                            .font(.headline)
                        HStack {
                            TextField("Absolute path to python", text: $viewModel.pythonExecutablePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") { viewModel.choosePythonExecutable() }
                        }

                        Text("Worker Script")
                            .font(.headline)
                        HStack {
                            TextField("Absolute path to analysis-worker/main.py", text: $viewModel.workerScriptPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") { viewModel.chooseWorkerScript() }
                        }

                        HStack {
                            Button("Use Detected Defaults") { viewModel.useDetectedAnalysisDefaults() }
                            Button("Save") { viewModel.saveAnalysisSettings() }
                            Button(viewModel.embeddingProfile.requiresAPIKey ? "Validate API Key" : "Validate Profile") {
                                viewModel.validateEmbeddingProfile()
                            }
                            .disabled(viewModel.validationStatus == .validating || !viewModel.isSelectedEmbeddingProfileSupported)
                        }

                        if !viewModel.settingsStatusMessage.isEmpty {
                            Text(viewModel.settingsStatusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Text("Bundled worker defaults are preferred so validation does not depend on a Documents-folder source checkout.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Embedding Coverage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Analyzed tracks: \(viewModel.analyzedTrackCount)")
                        Text("Tracks ready for active profile: \(viewModel.activeEmbeddingTrackCount)")
                        Text("Tracks needing fresh embeddings: \(viewModel.staleEmbeddingTrackCount)")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("DJ Library Sources") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.librarySources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
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
                                    .labelsHidden()
                                    .disabled(source.kind != .folderFallback && source.resolvedPath == nil)
                                }

                                Text(source.resolvedPath ?? "Not detected")
                                    .font(.footnote)
                                    .foregroundStyle(source.resolvedPath == nil ? .secondary : .primary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)

                                HStack {
                                    Text(source.status.displayText)
                                        .font(.footnote.weight(.semibold))
                                    if let lastSyncAt = source.lastSyncAt {
                                        Text("Last sync \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let lastError = source.lastError, !lastError.isEmpty {
                                    Text(lastError)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }

                        HStack {
                            Button("Library Setup") { viewModel.openInitialSetup() }
                            Button("Refresh Detection") { viewModel.refreshLibrarySourceDetection() }
                            Button("Sync Libraries") { viewModel.syncLibraries() }
                            Button("Auto-Import Rekordbox XML") { viewModel.autoImportRekordboxXML() }
                            Button("Import File…") { viewModel.loadExternalMetadata() }
                        }
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 2) {
                                AccessibilityMarker(
                                    identifier: "settings-sync-libraries-button",
                                    label: "Sync Libraries"
                                )
                                AccessibilityMarker(
                                    identifier: "settings-auto-import-rekordbox-xml-button",
                                    label: "Auto-Import Rekordbox XML"
                                )
                                AccessibilityMarker(
                                    identifier: "settings-import-metadata-file-button",
                                    label: "Import Metadata File"
                                )
                            }
                        }
                    }
                    .accessibilityIdentifier("settings-library-sources")
                }

                GroupBox("Manual Folder Fallback") {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.libraryRoots.isEmpty {
                            Text("No fallback folder configured.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.libraryRoots, id: \.self) { root in
                                HStack {
                                    Text(root)
                                        .lineLimit(2)
                                    Spacer()
                                    Button("Remove") { viewModel.removeLibraryRoot(root) }
                                }
                            }
                        }

                        HStack {
                            Button("Choose Folder") { viewModel.addLibraryRoot() }
                            Button("Rescan Folder") { viewModel.runFallbackScan() }
                        }
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("settings-info-view")
    }
}

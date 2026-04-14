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
                        Text("Embedding Provider")
                            .font(.headline)
                        Picker("Embedding Provider", selection: $viewModel.embeddingProvider) {
                            ForEach(EmbeddingProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isEmbeddingProviderLocked)

                        Text(viewModel.isEmbeddingProviderLocked
                             ? "Embedding provider is locked for this project to prevent vector DB mixing."
                             : "Choose once before first save. After save, this project uses only one embedding provider.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text("Gemini API Key")
                            .font(.headline)
                        SecureField("Paste your Gemini API key", text: $viewModel.geminiAPIKey)
                            .textFieldStyle(.roundedBorder)

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
                            Button("Validate Setup") { viewModel.validateAnalysisSetup() }
                        }

                        if !viewModel.settingsStatusMessage.isEmpty {
                            Text(viewModel.settingsStatusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if !viewModel.workerHealthSummary.isEmpty {
                            Text(viewModel.workerHealthSummary)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Library Roots") {
                    VStack(alignment: .leading, spacing: 12) {
                        List(viewModel.libraryRoots, id: \.self) { root in
                            HStack {
                                Text(root)
                                    .lineLimit(2)
                                Spacer()
                                Button("Remove") { viewModel.removeLibraryRoot(root) }
                            }
                        }
                        .frame(minHeight: 180)

                        HStack {
                            Button("Add Root") { viewModel.addLibraryRoot() }
                            Button("Rescan") { viewModel.runScan() }
                        }
                    }
                }
            }
            .padding()
        }
    }
}

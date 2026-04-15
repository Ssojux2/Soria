import SwiftUI

struct AnalysisView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let canAnalyze = viewModel.canRunAnalysis

        VStack(alignment: .leading, spacing: 14) {
            Text("Analysis")
                .font(.title2.bold())

            if !viewModel.selectedTracks.isEmpty {
                Text("Selected: \(viewModel.selectedTrackSummaryLabel)")
                    .foregroundStyle(.secondary)
            } else {
                Text("Select one or more tracks from Library to analyze.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Scope") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Analysis Scope", selection: $viewModel.analysisScope) {
                        ForEach(AnalysisScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.analysisScope.helperText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Analysis Focus", selection: $viewModel.analysisFocus) {
                        ForEach(AnalysisFocus.allCases) { focus in
                            Text(focus.displayName).tag(focus)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(viewModel.analysisFocus.helperText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Profile Readiness") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profile: \(viewModel.embeddingProfile.displayName)")
                    Text("Validation: \(viewModel.validationStatus.summaryText)")
                    Text("Active embeddings: \(viewModel.activeEmbeddingTrackCount) / \(viewModel.tracks.count)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(viewModel.isAnalyzing ? "Processing..." : "Analyze") {
                    viewModel.requestAnalysis()
                }
                .disabled(!canAnalyze)

                Button("Cancel") {
                    viewModel.cancelAnalysis()
                }
                .disabled(!viewModel.isAnalyzing)
                .tint(.red)

                if !viewModel.hasValidatedEmbeddingProfile {
                    Text("Validate the active embedding profile in Settings before running analysis.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.analysisQueueProgressText.isEmpty {
                Text(viewModel.analysisQueueProgressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.analysisErrorMessage.isEmpty {
                Text(viewModel.analysisErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !viewModel.selectedTracks.isEmpty {
                GroupBox("Selected Track Status") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.selectedTracks, id: \.id) { track in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                    Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(viewModel.analysisStatusText(for: track))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(viewModel.analysisStatusIsTransient(for: track) ? .blue : .secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let analysis = viewModel.selectedTrackAnalysis {
                GroupBox("Latest Feature Summary") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Brightness \(String(format: "%.3f", analysis.brightness)) • " +
                            "Onset \(String(format: "%.3f", analysis.onsetDensity)) • " +
                            "Rhythm \(String(format: "%.3f", analysis.rhythmicDensity))"
                        )
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)

                        Text("Focus: \(analysis.analysisFocus.displayName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Tags: \(analysis.mixabilityTags.isEmpty ? "-" : analysis.mixabilityTags.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Embedding Profile: \(viewModel.selectedTrack?.embeddingProfileID ?? "None")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding()
        .alert("Analyze Entire Library?", isPresented: $viewModel.isShowingAnalyzeAllConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelAnalyzeAllTracks()
            }
            Button("Analyze") {
                viewModel.confirmAnalyzeAllTracks()
            }
        } message: {
            Text(viewModel.analyzeAllConfirmationMessage)
        }
    }
}

import SwiftUI

struct AnalysisView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysis").font(.title2.bold())
            if let track = viewModel.selectedTrack {
                Text("Selected: \(track.title) - \(track.artist)")
                Button(viewModel.isAnalyzing ? "Analyzing..." : "Analyze Selected Track") {
                    viewModel.analyzeSelectedTrack()
                }
                .disabled(viewModel.isAnalyzing)
                Button("Analyze Unanalyzed Tracks") {
                    viewModel.analyzeUnanalyzedTracks()
                }
                .disabled(viewModel.isAnalyzing || viewModel.tracks.isEmpty)
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
                if let analysis = viewModel.selectedTrackAnalysis {
                    Divider()
                    Text("Latest feature summary")
                        .font(.headline)
                    Text("Brightness \(String(format: "%.3f", analysis.brightness)) • Onset \(String(format: "%.3f", analysis.onsetDensity)) • Rhythm \(String(format: "%.3f", analysis.rhythmicDensity))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select a track from Library")
            }
            Spacer()
        }
        .padding()
    }
}

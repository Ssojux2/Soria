import SwiftUI

struct ScanJobsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Jobs").font(.title2.bold())
            ProgressView(value: Double(viewModel.scanProgress.scannedFiles), total: Double(max(viewModel.scanProgress.totalFiles, 1)))
            Text("Running: \(viewModel.scanProgress.isRunning ? "Yes" : "No")")
            Text("Current: \(viewModel.scanProgress.currentFile)")
            Text("Scanned: \(viewModel.scanProgress.scannedFiles) / \(viewModel.scanProgress.totalFiles)")
            Text("Indexed: \(viewModel.scanProgress.indexedFiles)")
            Text("Skipped: \(viewModel.scanProgress.skippedFiles)")
            Text("Duplicates: \(viewModel.scanProgress.duplicateFiles)")
            Spacer()
        }
        .padding()
    }
}

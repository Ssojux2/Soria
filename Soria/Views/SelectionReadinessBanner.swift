import SwiftUI

/// Prompts the user to finish preparing a partly-ready selection.
///
/// Used by the Mix Assistant, which cannot score tracks that have no embeddings
/// yet. Previously it shared a file with a retired preparation pane; it lives on
/// its own now so its one caller is obvious.
struct SelectionReadinessBanner: View {
    let readiness: SelectionReadiness
    let canAnalyzePending: Bool
    let onAnalyzePending: () -> Void
    let onContinueWithReady: () -> Void
    let onReviewSelection: () -> Void

    var body: some View {
        GroupBox(readiness.bannerTitle) {
            VStack(alignment: .leading, spacing: 12) {
                Text(readiness.bannerMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Prepare Missing Tracks") {
                        onAnalyzePending()
                    }
                    .disabled(!canAnalyzePending)

                    if readiness.hasReadyTracks {
                        Button("Continue With Ready Tracks") {
                            onContinueWithReady()
                        }
                    }

                    Button("Review Selection") {
                        onReviewSelection()
                    }

                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

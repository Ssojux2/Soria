import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search")
                .font(.title2.bold())
            Text("Semantic search is now focused inside Mix Assistant's Build Mixset workflow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Open Mix Assistant") {
                viewModel.openMixAssistant(mode: .buildMixset)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("search-info-view")
    }
}

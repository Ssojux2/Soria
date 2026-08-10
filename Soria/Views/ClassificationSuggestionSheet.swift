import SwiftUI

/// Reviews the tags Soria thinks belong on untagged tracks.
///
/// Every row starts unaccepted. Nothing here writes to the library until the user
/// presses Apply, and only the rows they ticked are written — a suggestion engine
/// that retags a five-thousand-track library on its own is worse than one that
/// suggests nothing.
struct ClassificationSuggestionSheet: View {
    let suggestions: [ClassificationSuggestionEngine.Suggestion]
    let tracksByID: [UUID: Track]
    let tagCatalog: TagCatalog
    let onApply: ([ClassificationSuggestionEngine.Suggestion]) -> Void
    let onCancel: () -> Void

    @State private var acceptedTrackIDs: Set<UUID> = []

    /// Rows at or above this confidence are what "Accept confident matches"
    /// selects. Set higher than the threshold that produced the list: being
    /// offered a match and being sure enough to take it in bulk are different bars.
    private static let bulkAcceptThreshold: Double = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if suggestions.isEmpty {
                emptyState
            } else {
                suggestionList
            }

            Divider()

            footer
        }
        .padding(18)
        .frame(width: 620, height: 500)
        .accessibilityIdentifier("classification-suggestion-sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggested tags")
                .font(.headline)
            Text("Learned from the tracks you have already tagged. Nothing is applied until you press Apply.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No confident matches right now.")
                .font(.headline)
            Text("Tag a few more tracks and try again — the suggestions get sharper as your vocabulary grows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("suggestion-empty-state")
    }

    private var suggestionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        track: tracksByID[suggestion.trackID],
                        tagCatalog: tagCatalog,
                        isAccepted: acceptedTrackIDs.contains(suggestion.trackID)
                    ) {
                        if acceptedTrackIDs.contains(suggestion.trackID) {
                            acceptedTrackIDs.remove(suggestion.trackID)
                        } else {
                            acceptedTrackIDs.insert(suggestion.trackID)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Accept confident matches") {
                acceptedTrackIDs = Set(
                    suggestions
                        .filter { ($0.tags.first?.confidence ?? 0) >= Self.bulkAcceptThreshold }
                        .map(\.trackID)
                )
            }
            .disabled(suggestions.isEmpty)
            .accessibilityIdentifier("suggestion-accept-confident-button")

            Spacer()

            Text("\(acceptedTrackIDs.count) of \(suggestions.count) selected")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("suggestion-accepted-count")

            Button("Cancel", role: .cancel, action: onCancel)

            Button("Apply") {
                onApply(suggestions.filter { acceptedTrackIDs.contains($0.trackID) })
            }
            .keyboardShortcut(.defaultAction)
            .disabled(acceptedTrackIDs.isEmpty)
            .accessibilityIdentifier("suggestion-apply-button")
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: ClassificationSuggestionEngine.Suggestion
    let track: Track?
    let tagCatalog: TagCatalog
    let isAccepted: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isAccepted }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Accept suggestion")

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Unknown track")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(tagNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let confidence = suggestion.tags.first?.confidence {
                HStack(spacing: 6) {
                    ProgressView(value: confidence)
                        .progressViewStyle(.linear)
                        .frame(width: 44)
                    Text("\(Int((confidence * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("suggestion-row-\(accessibilitySlug(for: track?.title ?? "unknown"))")
    }

    private var tagNames: String {
        let names = suggestion.tags.compactMap { tagCatalog.tag(id: $0.tagID)?.name }
        return names.isEmpty ? "—" : "→ " + names.joined(separator: ", ")
    }
}

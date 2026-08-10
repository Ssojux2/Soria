import SwiftUI

struct AccessibilityMarker: View {
    let identifier: String
    let label: String

    var body: some View {
        Text(label.isEmpty ? " " : label)
            .id("\(identifier)-\(label)")
            .font(.system(size: 1))
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}

/// Turns arbitrary text into the kebab-case suffix this app's accessibility
/// identifiers use, e.g. `library-visible-track-<slug>`.
///
/// Global rather than private to a view because the crate tree, the tag panel,
/// and the track table all mint identifiers from user-authored names, and three
/// copies of this would eventually disagree about what a slug looks like — which
/// UI tests would then encode.
func accessibilitySlug(for text: String) -> String {
    let segments = text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    return segments.isEmpty ? "empty" : segments.joined(separator: "-")
}

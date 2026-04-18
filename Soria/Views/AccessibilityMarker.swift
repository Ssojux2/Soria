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

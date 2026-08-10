import SwiftUI

/// The small controls that show and set a track's classification.
///
/// Shared between the Library table and the classifier panel so a rating looks
/// and behaves the same wherever it appears. Kept UI-only — the value types they
/// render live in `TrackClassificationModels` and know nothing about SwiftUI.

extension TrackColorLabel {
    /// The swatch colour. Defined from the model's reference components so the
    /// palette has exactly one definition and the nearest-match importer and the
    /// view can never drift apart.
    var swatchColor: Color {
        let rgb = components
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Rating

/// Five stars, click to set, click the current value to clear.
///
/// Zero stars means unrated rather than rated-zero, matching Serato and
/// rekordbox, which is why clearing is reachable at all.
struct RatingStarsView: View {
    let rating: TrackRating?
    var isInteractive: Bool = true
    var onChange: ((TrackRating?) -> Void)?

    private var stars: Int { rating?.stars ?? 0 }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...TrackRating.maximumStars, id: \.self) { position in
                star(at: position)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(stars == 0 ? "Unrated" : "\(stars) of 5")
    }

    @ViewBuilder
    private func star(at position: Int) -> some View {
        let isFilled = position <= stars
        let symbol = Image(systemName: isFilled ? "star.fill" : "star")
            .font(.caption2)
            .foregroundStyle(isFilled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

        if isInteractive, let onChange {
            Button {
                // Clicking the current rating clears it — otherwise there is no
                // way back to unrated once a star has been set.
                onChange(stars == position ? nil : TrackRating(position))
            } label: {
                symbol
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rating-star-\(position)")
        } else {
            symbol
        }
    }
}

// MARK: - Energy

/// Ten segments read as a length. The number sits beside it for the cases where
/// an exact value matters, but the bar is what makes a list scannable.
struct EnergyMeterView: View {
    let energy: TrackEnergy?
    var showsValue: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 1.5) {
                ForEach(TrackEnergy.minimumLevel...TrackEnergy.maximumLevel, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(level <= (energy?.level ?? 0) ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 3, height: 10)
                }
            }

            if showsValue, let energy {
                Text("\(energy.level)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .leading)
            }
        }
        .opacity(energy == nil ? 0.35 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Energy")
        .accessibilityValue(energy.map { "\($0.level) of 10" } ?? "Not analyzed")
    }
}

// MARK: - Colour

struct ColorLabelDot: View {
    let color: TrackColorLabel?

    var body: some View {
        Group {
            if let color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.swatchColor)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityLabel(color?.displayName ?? "No colour")
    }
}

/// The eight-swatch picker. Clicking the active colour clears it.
struct ColorLabelPicker: View {
    let selected: Set<TrackColorLabel>
    var allowsMultiple: Bool = false
    let onToggle: (TrackColorLabel) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(TrackColorLabel.allCases) { color in
                Button {
                    onToggle(color)
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.swatchColor)
                        .frame(width: 18, height: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.primary, lineWidth: selected.contains(color) ? 2 : 0)
                        }
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(selected.contains(color) ? .isSelected : [])
                .accessibilityIdentifier("color-swatch-\(color.rawValue)")
            }
        }
    }
}

// MARK: - Tag chip

/// A tag in one of three states.
///
/// The middle state is the reason this is not a checkbox: when only part of the
/// selection carries a tag, rendering it as "off" invites a click that would
/// strip it from the tracks that had it.
struct TagChipView: View {
    let name: String
    let state: TrackTagIndex.SelectionState
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption)
                if state != .none {
                    Image(systemName: state == .all ? "checkmark" : "minus")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(background)
            .overlay {
                Capsule().strokeBorder(state == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint), lineWidth: 1)
            }
            .clipShape(Capsule())
            .foregroundStyle(state == .all ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state == .all ? .isSelected : [])
        .accessibilityValue(accessibilityValue)
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .all:
            Capsule().fill(.tint)
        case .partial:
            Capsule().fill(.tint.opacity(0.18))
        case .none:
            Capsule().fill(.clear)
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .all: return "Applied to every selected track"
        case .partial: return "Applied to some selected tracks"
        case .none: return "Not applied"
        }
    }
}

/// Applies an accessibility identifier only when one was supplied, so callers
/// that do not need a test hook are not forced to invent one.
private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

// MARK: - Source badge

/// Where a value came from. Only shown when it is not the user, because "you set
/// this" is the boring case and labelling every row with it would be noise.
struct MetadataSourceBadge: View {
    let source: TrackMetadataSource?

    var body: some View {
        if let source, source != .user {
            Text(source.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
        }
    }
}

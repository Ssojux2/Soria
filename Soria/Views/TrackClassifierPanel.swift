import SwiftUI

/// The right pane of the Library: say what the selected tracks are, or narrow the
/// table down to the ones you mean.
///
/// Two tabs rather than one long column because the two jobs alternate rather
/// than combine — you filter down to a pile, then classify the pile, then filter
/// again. Showing both at once would halve the room each gets for no benefit.
struct TrackClassifierPanel: View {
    @ObservedObject var model: LibraryBrowserModel
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.classifierTab) {
                ForEach(LibraryBrowserModel.ClassifierTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            .accessibilityIdentifier("classifier-tab-picker")

            Divider()

            ScrollView {
                switch model.classifierTab {
                case .tag:
                    TagTabView(model: model, viewModel: viewModel)
                case .filter:
                    FilterTabView(model: model)
                }
            }

            if !model.statusMessage.isEmpty {
                Divider()
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier("classifier-status-message")
            }
        }
        .frame(minWidth: 208, idealWidth: 244, maxWidth: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-classifier-panel")
    }
}

// MARK: - Tag tab

private struct TagTabView: View {
    @ObservedObject var model: LibraryBrowserModel
    @ObservedObject var viewModel: AppViewModel

    @State private var newTagSlot: TagCategorySlot?
    @State private var newTagName = ""

    private var selectedTracks: [Track] { viewModel.selectedTracks }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selectionSummary)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("classifier-selection-summary")

            if selectedTracks.isEmpty {
                Text("Select a track to rate it, set its energy, or tag it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                attributeControls
            }

            Divider()

            ForEach(model.tagCatalog.categories) { category in
                categorySection(category)
            }

            if !model.tagCatalog.isEmpty {
                Divider()
                Button {
                    model.buildSuggestions()
                } label: {
                    Label(
                        model.isBuildingSuggestions ? "Finding matches…" : "Suggest tags",
                        systemImage: "sparkles"
                    )
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isBuildingSuggestions)
                .help("Scores untagged tracks against the ones you already tagged. Nothing is applied until you accept it.")
                .accessibilityIdentifier("suggest-tags-button")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $model.isSuggestionSheetPresented) {
            ClassificationSuggestionSheet(
                suggestions: model.suggestions,
                tracksByID: Dictionary(uniqueKeysWithValues: viewModel.tracks.map { ($0.id, $0) }),
                tagCatalog: model.tagCatalog,
                onApply: { model.applySuggestions($0) },
                onCancel: { model.dismissSuggestions() }
            )
        }
    }

    private var selectionSummary: String {
        switch selectedTracks.count {
        case 0: return "Nothing selected"
        case 1: return "1 track selected"
        default: return "\(selectedTracks.count) tracks selected"
        }
    }

    @ViewBuilder
    private var attributeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledClassifierRow(title: "Rating") {
                HStack(spacing: 6) {
                    RatingStarsView(rating: sharedRating) { newRating in
                        model.setRating(newRating, on: selectedTracks)
                    }
                    if selectedTracks.count == 1 {
                        MetadataSourceBadge(source: selectedTracks[0].classification.ratingSource)
                    }
                }
                .accessibilityIdentifier("classifier-rating")
            }

            LabeledClassifierRow(title: "Energy") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        EnergyMeterView(energy: sharedEnergy)
                        if selectedTracks.count == 1 {
                            MetadataSourceBadge(source: selectedTracks[0].classification.energySource)
                        }
                    }
                    Slider(
                        value: energyBinding,
                        in: Double(TrackEnergy.minimumLevel)...Double(TrackEnergy.maximumLevel),
                        step: 1
                    )
                    .controlSize(.mini)
                    .accessibilityIdentifier("classifier-energy-slider")
                }
            }

            LabeledClassifierRow(title: "Colour") {
                ColorLabelPicker(selected: sharedColor.map { [$0] } ?? []) { color in
                    // Clicking the colour the selection already has clears it.
                    model.setColorLabel(sharedColor == color ? nil : color, on: selectedTracks)
                }
            }
        }
    }

    /// The value shown when a multi-track selection agrees, and nil when it does
    /// not — so a mixed selection never displays one track's rating as if it were
    /// everybody's.
    private var sharedRating: TrackRating? {
        let values = Set(selectedTracks.map { $0.classification.rating })
        return values.count == 1 ? values.first ?? nil : nil
    }

    private var sharedEnergy: TrackEnergy? {
        let values = Set(selectedTracks.map { $0.classification.energy })
        return values.count == 1 ? values.first ?? nil : nil
    }

    private var sharedColor: TrackColorLabel? {
        let values = Set(selectedTracks.map { $0.classification.colorLabel })
        return values.count == 1 ? values.first ?? nil : nil
    }

    private var energyBinding: Binding<Double> {
        Binding(
            get: { Double(sharedEnergy?.level ?? TrackEnergy.minimumLevel) },
            set: { model.setEnergy(TrackEnergy(Int($0)), on: selectedTracks) }
        )
    }

    @ViewBuilder
    private func categorySection(_ category: TagCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category.name)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.tertiary)

            FlowRow(spacing: 4) {
                ForEach(model.tagCatalog.tags(in: category.slot)) { tag in
                    TagChipView(
                        name: tag.name,
                        state: model.selectionState(for: tag.id),
                        identifier: "tag-chip-\(category.slot.rawValue)-\(accessibilitySlug(for: tag.name))"
                    ) {
                        model.toggleTag(tag.id)
                    }
                    .contextMenu {
                        Button("Delete Tag", role: .destructive) { model.deleteTag(tag.id) }
                    }
                }

                if newTagSlot == category.slot {
                    TextField("Tag name", text: $newTagName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 110)
                        .onSubmit(commitNewTag)
                        .accessibilityIdentifier("tag-new-field-\(category.slot.rawValue)")
                } else {
                    Button {
                        newTagSlot = category.slot
                        newTagName = ""
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .overlay { Capsule().strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Add a tag to \(category.name)")
                    .accessibilityIdentifier("tag-add-button-\(category.slot.rawValue)")
                }
            }
        }
    }

    private func commitNewTag() {
        guard let slot = newTagSlot else { return }
        model.addTag(named: newTagName, to: slot)
        newTagName = ""
        newTagSlot = nil
    }
}

private struct LabeledClassifierRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            content
        }
    }
}

// MARK: - Filter tab

private struct FilterTabView: View {
    @ObservedObject var model: LibraryBrowserModel

    @State private var isNamingCrate = false
    @State private var crateName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(model.classificationFilter.activeConstraintCount) active")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { model.clearClassificationFilter() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(model.classificationFilter.isEmpty)
                    .accessibilityIdentifier("filter-clear-button")
            }

            bpmField
            ratingField
            energyField
            keyField
            colorField
            tagField

            Divider()
            saveAsCrate
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Turns the current filter into a crate that keeps matching new tracks.
    ///
    /// The naming field appears in place rather than in a dialog: the filter you
    /// are naming is right there, and a sheet would cover it.
    @ViewBuilder
    private var saveAsCrate: some View {
        if isNamingCrate {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Crate name", text: $crateName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit(commit)
                    .accessibilityIdentifier("smart-crate-name-field")

                HStack {
                    Button("Cancel") { isNamingCrate = false }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save", action: commit)
                        .font(.caption)
                        .disabled(crateName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("smart-crate-confirm-button")
                }
            }
        } else {
            Button {
                crateName = ""
                isNamingCrate = true
            } label: {
                Label("Save as Smart Crate", systemImage: "sparkles.rectangle.stack")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.classificationFilter.isEmpty)
            .accessibilityIdentifier("save-smart-crate-button")
        }
    }

    private func commit() {
        model.saveFilterAsSmartCrate(named: crateName)
        crateName = ""
        isNamingCrate = false
    }

    private var bpmField: some View {
        LabeledClassifierRow(title: "BPM") {
            HStack(spacing: 6) {
                OptionalNumberField(
                    placeholder: "min",
                    value: $model.classificationFilter.minimumBPM,
                    identifier: "filter-bpm-min"
                )
                Text("–").foregroundStyle(.tertiary)
                OptionalNumberField(
                    placeholder: "max",
                    value: $model.classificationFilter.maximumBPM,
                    identifier: "filter-bpm-max"
                )
            }
        }
    }

    private var ratingField: some View {
        LabeledClassifierRow(title: "Rating at least") {
            HStack(spacing: 1) {
                ForEach(1...TrackRating.maximumStars, id: \.self) { stars in
                    Button {
                        model.classificationFilter.minimumRating =
                            model.classificationFilter.minimumRating == stars ? nil : stars
                    } label: {
                        Image(systemName: stars <= (model.classificationFilter.minimumRating ?? 0) ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(stars <= (model.classificationFilter.minimumRating ?? 0)
                                ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filter-rating-\(stars)")
                }
            }
        }
    }

    private var energyField: some View {
        LabeledClassifierRow(title: "Energy") {
            HStack(spacing: 6) {
                OptionalIntField(
                    placeholder: "min",
                    value: $model.classificationFilter.minimumEnergy,
                    identifier: "filter-energy-min"
                )
                Text("–").foregroundStyle(.tertiary)
                OptionalIntField(
                    placeholder: "max",
                    value: $model.classificationFilter.maximumEnergy,
                    identifier: "filter-energy-max"
                )
            }
        }
    }

    private var keyField: some View {
        LabeledClassifierRow(title: "Key") {
            VStack(alignment: .leading, spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 6), spacing: 3) {
                    ForEach(CamelotKey.all) { key in
                        Button {
                            model.toggleFilterKey(key)
                        } label: {
                            Text(key.notation)
                                .font(.system(size: 9, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(
                                    model.classificationFilter.camelotNotations.contains(key.notation)
                                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 3)
                                )
                                .foregroundStyle(
                                    model.classificationFilter.camelotNotations.contains(key.notation)
                                        ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("filter-key-\(key.notation.lowercased())")
                    }
                }

                Toggle(isOn: $model.classificationFilter.includesHarmonicNeighbours) {
                    Text("Include harmonic matches").font(.caption)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("filter-harmonic-toggle")
            }
        }
    }

    private var colorField: some View {
        LabeledClassifierRow(title: "Colour") {
            ColorLabelPicker(
                selected: model.classificationFilter.colorLabels,
                allowsMultiple: true
            ) { color in
                model.toggleFilterColor(color)
            }
        }
    }

    @ViewBuilder
    private var tagField: some View {
        if !model.tagCatalog.isEmpty {
            LabeledClassifierRow(title: "Tags") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $model.classificationFilter.tagMatch) {
                        ForEach(LibraryClassificationFilter.TagMatch.allCases) { match in
                            Text(match.displayName).tag(match)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("filter-tag-match-picker")

                    FlowRow(spacing: 4) {
                        ForEach(model.tagCatalog.tags) { tag in
                            TagChipView(
                                name: tag.name,
                                state: model.classificationFilter.tagIDs.contains(tag.id) ? .all : .none,
                                identifier: "filter-tag-\(accessibilitySlug(for: tag.name))"
                            ) {
                                model.toggleFilterTag(tag.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Small inputs

/// A numeric field that stays empty rather than showing 0 when unset — the
/// difference between "no BPM filter" and "BPM at least zero" is the whole point.
private struct OptionalNumberField: View {
    let placeholder: String
    @Binding var value: Double?
    let identifier: String

    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(identifier)
    }

    private var text: Binding<String> {
        Binding(
            get: { value.map { String(format: "%.0f", $0) } ?? "" },
            set: { value = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Double($0) }
        )
    }
}

private struct OptionalIntField: View {
    let placeholder: String
    @Binding var value: Int?
    let identifier: String

    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(identifier)
    }

    private var text: Binding<String> {
        Binding(
            get: { value.map(String.init) ?? "" },
            set: { value = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int($0) }
        )
    }
}

/// Wraps its children onto as many lines as they need.
///
/// Tag names are user-authored and vary from "Warm" to "Late Night Closer", so
/// neither a fixed grid nor a single `HStack` works — the first wastes the panel's
/// width, the second clips.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widestRow = max(widestRow, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        widestRow = max(widestRow, rowWidth)
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

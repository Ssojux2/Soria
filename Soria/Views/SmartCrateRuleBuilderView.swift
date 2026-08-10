import SwiftUI

/// Edits the rules behind a smart crate.
///
/// Reached from the crate's context menu in the tree. The usual way a crate gets
/// created is "Save as Smart Crate" in the Filter tab — this is where you go when
/// the rules need something the filter panel cannot express, like "artist
/// contains" or "album is not".
struct SmartCrateRuleBuilderView: View {
    let crateName: String
    let tagCatalog: TagCatalog
    /// Recomputed as the rules change, so the count under the list always
    /// describes the rules on screen rather than the ones last saved.
    let matchCount: (SmartCrateRuleSet) -> Int
    let onSave: (SmartCrateRuleSet) -> Void
    let onCancel: () -> Void

    @State private var ruleSet: SmartCrateRuleSet

    init(
        crateName: String,
        ruleSet: SmartCrateRuleSet,
        tagCatalog: TagCatalog,
        matchCount: @escaping (SmartCrateRuleSet) -> Int,
        onSave: @escaping (SmartCrateRuleSet) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.crateName = crateName
        self.tagCatalog = tagCatalog
        self.matchCount = matchCount
        self.onSave = onSave
        self.onCancel = onCancel
        _ruleSet = State(initialValue: ruleSet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(crateName)
                .font(.headline)

            HStack(spacing: 6) {
                Text("Match")
                Picker("", selection: $ruleSet.match) {
                    ForEach(SmartCrateRuleSet.Match.allCases) { match in
                        Text(match.displayName).tag(match)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .accessibilityIdentifier("smart-crate-match-picker")
                Text("of the following")
                Spacer()
            }
            .font(.callout)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($ruleSet.rules) { $rule in
                        SmartCrateRuleRow(rule: $rule, tagCatalog: tagCatalog) {
                            ruleSet.rules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 300)

            HStack {
                Button {
                    ruleSet.rules.append(SmartCrateRule(field: .artist, op: .contains, value: .text("")))
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .accessibilityIdentifier("smart-crate-add-rule-button")

                Spacer()

                Text(matchSummary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("smart-crate-match-count")
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onSave(ruleSet) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ruleSet.validRules.isEmpty)
                    .accessibilityIdentifier("smart-crate-save-button")
            }
        }
        .padding(18)
        .frame(width: 540)
        .accessibilityIdentifier("smart-crate-rule-builder")
    }

    private var matchSummary: String {
        guard !ruleSet.validRules.isEmpty else { return "No complete rules yet" }
        let count = matchCount(ruleSet)
        return "\(WorkspaceDashboardState.formatted(count)) \(count == 1 ? "track" : "tracks") match"
    }
}

private struct SmartCrateRuleRow: View {
    @Binding var rule: SmartCrateRule
    let tagCatalog: TagCatalog
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $rule.field) {
                ForEach(SmartCrateField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .onChange(of: rule.field) { _, newField in
                // The operator list is per field, so a field change can strand an
                // operator that no longer applies — snap to the first valid one
                // instead of leaving a rule that can never be satisfied.
                if !newField.supportedOperators.contains(rule.op) {
                    rule.op = newField.supportedOperators.first ?? .is
                }
                rule.value = Self.defaultValue(for: newField, op: rule.op, tagCatalog: tagCatalog)
            }

            Picker("", selection: $rule.op) {
                ForEach(rule.field.supportedOperators) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 132)
            .onChange(of: rule.op) { _, newOperator in
                rule.value = Self.defaultValue(for: rule.field, op: newOperator, tagCatalog: tagCatalog)
            }

            valueEditor

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove rule")
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        if !rule.op.requiresValue {
            Spacer()
        } else {
            switch rule.field {
            case .tag:
                Picker("", selection: tagBinding) {
                    Text("Choose a tag").tag(UUID?.none)
                    ForEach(tagCatalog.tags) { tag in
                        Text(tag.name).tag(UUID?.some(tag.id))
                    }
                }
                .labelsHidden()

            case .colorLabel:
                Picker("", selection: colorBinding) {
                    ForEach(TrackColorLabel.allCases) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()

            case .bpm, .rating, .energy, .dateAdded:
                if rule.op == .between {
                    HStack(spacing: 4) {
                        TextField("from", text: rangeBinding(isUpper: false))
                            .textFieldStyle(.roundedBorder)
                        Text("–").foregroundStyle(.tertiary)
                        TextField("to", text: rangeBinding(isUpper: true))
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    TextField(rule.field == .dateAdded ? "days" : "value", text: numberBinding)
                        .textFieldStyle(.roundedBorder)
                }

            default:
                TextField("value", text: textBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: Bindings

    private var textBinding: Binding<String> {
        Binding(
            get: { rule.value.textValue ?? "" },
            set: { rule.value = .text($0) }
        )
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { rule.value.numberValue.map { String(format: "%g", $0) } ?? "" },
            set: { rule.value = Double($0).map { SmartCrateValue.number($0) } ?? .none }
        )
    }

    private func rangeBinding(isUpper: Bool) -> Binding<String> {
        Binding(
            get: {
                guard case let .range(lower, upper) = rule.value else { return "" }
                return String(format: "%g", isUpper ? upper : lower)
            },
            set: { newValue in
                var lower = 0.0
                var upper = 0.0
                if case let .range(existingLower, existingUpper) = rule.value {
                    lower = existingLower
                    upper = existingUpper
                }
                let parsed = Double(newValue) ?? 0
                rule.value = .range(isUpper ? lower : parsed, isUpper ? parsed : upper)
            }
        )
    }

    private var tagBinding: Binding<UUID?> {
        Binding(
            get: {
                if case let .tag(id) = rule.value { return id }
                return nil
            },
            set: { rule.value = $0.map { SmartCrateValue.tag($0) } ?? .none }
        )
    }

    private var colorBinding: Binding<TrackColorLabel> {
        Binding(
            get: {
                if case let .color(color) = rule.value { return color }
                return .pink
            },
            set: { rule.value = .color($0) }
        )
    }

    /// A value of the right shape for the field and operator, so switching
    /// between them never leaves a rule holding a value it cannot use.
    private static func defaultValue(
        for field: SmartCrateField,
        op: SmartCrateOperator,
        tagCatalog: TagCatalog
    ) -> SmartCrateValue {
        guard op.requiresValue else { return .none }

        switch field {
        case .tag:
            return tagCatalog.tags.first.map { SmartCrateValue.tag($0.id) } ?? .none
        case .colorLabel:
            return .color(.pink)
        case .bpm, .rating, .energy, .dateAdded:
            return op == .between ? .range(0, 0) : .none
        default:
            return .text("")
        }
    }
}

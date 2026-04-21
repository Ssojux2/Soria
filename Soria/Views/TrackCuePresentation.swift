import Foundation

enum TrackCuePresentation {
    struct WaveformCueSource: Identifiable, Equatable {
        let source: ExternalDJMetadata.Source
        let kindLabel: String
        let indexLabel: String?
        let timeText: String
        let noteText: String?
        let sourceTag: String?

        var id: String {
            [
                source.rawValue,
                kindLabel,
                indexLabel ?? "",
                timeText,
                noteText ?? "",
                sourceTag ?? ""
            ].joined(separator: "|")
        }
    }

    struct WaveformCueGroup: Identifiable, Equatable {
        let kind: ExternalDJCuePoint.Kind
        let startSec: Double
        let endSec: Double?
        let color: String?
        let sources: [WaveformCueSource]

        var id: String {
            [
                kind.rawValue,
                String(format: "%.3f", startSec),
                endSec.map { String(format: "%.3f", $0) } ?? "",
                color ?? "",
                sources.map(\.id).joined(separator: ",")
            ].joined(separator: "|")
        }

        var isLoop: Bool {
            kind == .loop && (endSec ?? startSec) > startSec
        }

        var tooltipText: String {
            sources
                .map { source in
                    let note = source.noteText.map { " \($0)" } ?? ""
                    let slot = source.indexLabel.map { " \($0)" } ?? ""
                    let vendor = source.source.displayName
                    return "\(vendor) \(source.kindLabel)\(slot) @ \(source.timeText)\(note)"
                }
                .joined(separator: "\n")
        }
    }

    struct CueGroup: Identifiable, Equatable {
        let source: ExternalDJMetadata.Source
        let items: [CueItem]

        var id: String { source.rawValue }
    }

    struct CueItem: Identifiable, Equatable {
        let source: ExternalDJMetadata.Source
        let kind: ExternalDJCuePoint.Kind
        let kindLabel: String
        let indexLabel: String?
        let startSec: Double
        let timeText: String
        let noteText: String?
        let sourceTag: String?

        var id: String {
            [
                source.rawValue,
                kind.rawValue,
                String(format: "%.3f", startSec),
                indexLabel ?? "",
                noteText ?? "",
                sourceTag ?? ""
            ].joined(separator: "|")
        }
    }

    nonisolated static func groups(from metadata: [ExternalDJMetadata]) -> [CueGroup] {
        let entriesBySource = Dictionary(grouping: metadata, by: \.source)

        return ExternalDJMetadata.Source.allCases.compactMap { source in
            guard let entries = entriesBySource[source] else { return nil }

            var seen: Set<String> = []
            let items = entries
                .flatMap(\.cuePoints)
                .filter { cuePoint in
                    seen.insert(cueKey(for: cuePoint)).inserted
                }
                .sorted(by: cueSort)
                .map { cuePoint in
                    CueItem(
                        source: source,
                        kind: cuePoint.kind,
                        kindLabel: typeLabel(for: cuePoint.kind),
                        indexLabel: indexLabel(for: cuePoint),
                        startSec: cuePoint.startSec,
                        timeText: timeText(for: cuePoint.startSec),
                        noteText: normalizedText(cuePoint.name),
                        sourceTag: normalizedText(cuePoint.source)
                    )
                }

            return items.isEmpty ? nil : CueGroup(source: source, items: items)
        }
    }

    nonisolated static func waveformSummaryText(hasWaveformPreview: Bool, cueCount: Int) -> String {
        switch (hasWaveformPreview, cueCount > 0) {
        case (true, true):
            return "\(cueCount) cue marker\(cueCount == 1 ? "" : "s") loaded on the waveform."
        case (true, false):
            return "Waveform preview loaded. No imported cue points yet."
        case (false, true):
            return "Cue points are available, but no waveform preview was found."
        case (false, false):
            return "No waveform preview or cue points are available yet."
        }
    }

    nonisolated static func waveformCueGroups(from metadata: [ExternalDJMetadata]) -> [WaveformCueGroup] {
        let flattened = metadata
            .flatMap { entry in
                entry.cuePoints.map { cuePoint in
                    (source: entry.source, cuePoint: cuePoint)
                }
            }
            .sorted { lhs, rhs in
                if lhs.cuePoint.startSec == rhs.cuePoint.startSec {
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                return lhs.cuePoint.startSec < rhs.cuePoint.startSec
            }

        var results: [WaveformCueGroup] = []
        for candidate in flattened {
            let source = WaveformCueSource(
                source: candidate.source,
                kindLabel: typeLabel(for: candidate.cuePoint.kind),
                indexLabel: indexLabel(for: candidate.cuePoint),
                timeText: timeText(for: candidate.cuePoint.startSec),
                noteText: normalizedText(candidate.cuePoint.name),
                sourceTag: normalizedText(candidate.cuePoint.source)
            )

            if let last = results.last, canMergeWaveformCueGroup(last, with: candidate.cuePoint) {
                let mergedColor = normalizedText(last.color) ?? normalizedText(candidate.cuePoint.color)
                results[results.count - 1] = WaveformCueGroup(
                    kind: last.kind,
                    startSec: min(last.startSec, candidate.cuePoint.startSec),
                    endSec: mergedEndSec(existing: last.endSec, incoming: candidate.cuePoint.endSec),
                    color: mergedColor,
                    sources: (last.sources + [source]).sorted { $0.source.rawValue < $1.source.rawValue }
                )
                continue
            }

            results.append(
                WaveformCueGroup(
                    kind: candidate.cuePoint.kind,
                    startSec: candidate.cuePoint.startSec,
                    endSec: candidate.cuePoint.endSec,
                    color: normalizedText(candidate.cuePoint.color),
                    sources: [source]
                )
            )
        }

        return results
    }

    nonisolated static func typeLabel(for kind: ExternalDJCuePoint.Kind) -> String {
        switch kind {
        case .cue:
            return "Memory Cue"
        case .hotcue:
            return "Hot Cue"
        case .loop:
            return "Loop"
        case .unknown:
            return "Cue Marker"
        }
    }

    nonisolated static func timeText(for seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }

        let totalMilliseconds = Int((seconds * 1000.0).rounded())
        let totalSeconds = totalMilliseconds / 1000
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%d:%02d.%03d", minutes, secs, milliseconds)
    }

    nonisolated private static func cueSort(lhs: ExternalDJCuePoint, rhs: ExternalDJCuePoint) -> Bool {
        if lhs.startSec == rhs.startSec {
            return (lhs.index ?? Int.max) < (rhs.index ?? Int.max)
        }
        return lhs.startSec < rhs.startSec
    }

    nonisolated private static func indexLabel(for cuePoint: ExternalDJCuePoint) -> String? {
        guard let index = cuePoint.index else { return nil }

        switch cuePoint.kind {
        case .hotcue:
            return "Slot \(index)"
        case .loop:
            return "Loop \(index)"
        case .cue, .unknown:
            return nil
        }
    }

    nonisolated private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func cueKey(for cuePoint: ExternalDJCuePoint) -> String {
        let startMilliseconds = Int((cuePoint.startSec * 1000.0).rounded())
        let endMilliseconds = cuePoint.endSec.map { Int(($0 * 1000.0).rounded()) }
        let components: [String] = [
            cuePoint.kind.rawValue,
            String(startMilliseconds),
            endMilliseconds.map(String.init) ?? "",
            cuePoint.index.map(String.init) ?? "",
            normalizedText(cuePoint.name) ?? "",
            normalizedText(cuePoint.color) ?? "",
            normalizedText(cuePoint.source) ?? ""
        ]
        return components.joined(separator: "|")
    }

    nonisolated private static func canMergeWaveformCueGroup(
        _ group: WaveformCueGroup,
        with cuePoint: ExternalDJCuePoint
    ) -> Bool {
        guard group.kind == cuePoint.kind else { return false }
        guard abs(group.startSec - cuePoint.startSec) <= 0.05 else { return false }

        switch (group.endSec, cuePoint.endSec) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) <= 0.05
        default:
            return false
        }
    }

    nonisolated private static func mergedEndSec(existing: Double?, incoming: Double?) -> Double? {
        switch (existing, incoming) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }
}

import Foundation

enum TrackCuePresentation {
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
        [
            cuePoint.kind.rawValue,
            String(Int((cuePoint.startSec * 1000.0).rounded())),
            cuePoint.endSec.map { String(Int(($0 * 1000.0).rounded())) } ?? "",
            cuePoint.index.map(String.init) ?? "",
            normalizedText(cuePoint.name) ?? "",
            normalizedText(cuePoint.color) ?? "",
            normalizedText(cuePoint.source) ?? ""
        ].joined(separator: "|")
    }
}

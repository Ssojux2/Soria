import Foundation

struct ExternalCuePointParser: Sendable {
    private struct ParsedCuePoint: Codable, Sendable {
        let kind: String?
        let name: String?
        let index: Int?
        let start: Double?
        let time: Double?
        let end: Double?
        let duration: Double?
        let color: String?
    }

    nonisolated init() {}

    nonisolated func parseRekordboxCuePoints(from trackElement: XMLElement) -> [ExternalDJCuePoint] {
        let marks = trackElement.elements(forName: "POSITION_MARK")
        return marks.enumerated().compactMap { index, mark in
            guard let start = parseCueTime(mark.attribute(forName: "Start")?.stringValue)
                    ?? parseCueTime(mark.attribute(forName: "StartValue")?.stringValue) else {
                return nil
            }

            return ExternalDJCuePoint(
                kind: parseCueKind(mark.attribute(forName: "Type")?.stringValue),
                name: nilIfEmpty(mark.attribute(forName: "Name")?.stringValue),
                index: parseInt(mark.attribute(forName: "Num")?.stringValue) ?? (index + 1),
                startSec: start,
                endSec: parseCueTime(mark.attribute(forName: "End")?.stringValue),
                color: nilIfEmpty(mark.attribute(forName: "Colour")?.stringValue)
                    ?? nilIfEmpty(mark.attribute(forName: "Color")?.stringValue),
                source: "POSITION_MARK"
            )
        }
    }

    nonisolated func parseSeratoCuePoints(from row: [String: String]) -> [ExternalDJCuePoint] {
        let cueFieldGroups: [(String, ExternalDJCuePoint.Kind)] = [
            ("cue_points", .cue),
            ("cues", .cue),
            ("cuepoints", .cue),
            ("cue_points_json", .cue),
            ("cue_points_json_v2", .cue),
            ("hot_cues", .hotcue),
            ("hotcues", .hotcue),
            ("hotcue", .hotcue),
            ("hotcue_points", .hotcue),
            ("hotcue_json", .hotcue),
            ("hotcues_json", .hotcue),
            ("cues_json", .cue)
        ]

        var points: [ExternalDJCuePoint] = []
        for (field, kind) in cueFieldGroups {
            let value = row[field] ?? ""
            guard !value.isEmpty else { continue }
            points.append(contentsOf: parseCueValue(value, kind: kind, sourceName: field, startIndex: points.count + 1))
        }

        return normalize(points)
    }

    nonisolated func parseCuePoints(fromSerialized value: Any, kind: ExternalDJCuePoint.Kind, sourceName: String, startIndex: Int = 1) -> [ExternalDJCuePoint] {
        guard let payload = parseCuePointsPayload(from: value) else { return [] }
        return normalize(
            payload
                .compactMap { item -> ExternalDJCuePoint? in
                    let start = item.start ?? item.time ?? item.duration
                    guard let startSec = parseCueTime(start) else { return nil }
                    let parsedKind = parseCueKind(item.kind)
                    return ExternalDJCuePoint(
                        kind: parsedKind == .unknown ? kind : parsedKind,
                        name: item.name,
                        index: item.index,
                        startSec: startSec,
                        endSec: parseCueTime(item.end),
                        color: item.color,
                        source: sourceName
                    )
                }
                .withStartOffset(startIndex: startIndex)
        )
    }

    nonisolated func parseSQLiteCuePoint(
        from row: [String: Any?],
        trackIDColumns: [String],
        timeColumns: [String],
        endColumns: [String],
        nameColumns: [String],
        kindColumns: [String],
        indexColumns: [String],
        colorColumns: [String],
        fallbackKind: ExternalDJCuePoint.Kind,
        sourceName: String
    ) -> (trackID: String, cuePoint: ExternalDJCuePoint)? {
        guard
            let trackID = firstNonEmptyString(from: row, keys: trackIDColumns),
            let start = parseCueTime(firstValue(from: row, keys: timeColumns))
        else {
            return nil
        }

        let kindText = firstNonEmptyString(from: row, keys: kindColumns)
        let kind = parseCueKind(kindText ?? fallbackKind.rawValue)
        let end = parseCueTime(firstValue(from: row, keys: endColumns))
        let index = parseInt(firstValue(from: row, keys: indexColumns))
        let name = firstNonEmptyString(from: row, keys: nameColumns)
        let color = firstNonEmptyString(from: row, keys: colorColumns)

        return (
            trackID: trackID,
            cuePoint: ExternalDJCuePoint(
                kind: kind,
                name: name,
                index: index,
                startSec: start,
                endSec: end,
                color: color,
                source: sourceName
            )
        )
    }

    nonisolated func normalize(_ points: [ExternalDJCuePoint], duration: Double? = nil) -> [ExternalDJCuePoint] {
        let maxDuration = duration.flatMap { $0 > 0 ? $0 : nil }

        let sanitized = points.compactMap { point -> ExternalDJCuePoint? in
            guard point.startSec.isFinite else { return nil }
            var start = max(0, point.startSec)
            if let maxDuration, start > maxDuration { start = maxDuration }

            var end = point.endSec
        if let endValue = end, endValue.isFinite {
            if endValue < 0 {
                end = nil
            } else if let maxDuration, endValue > maxDuration {
                end = maxDuration
            }
        } else if end != nil {
            end = nil
        }

            if let endValue = end, endValue < start {
                end = nil
            }

            return ExternalDJCuePoint(
                kind: point.kind,
                name: nilIfEmpty(point.name),
                index: point.index,
                startSec: start,
                endSec: end,
                color: nilIfEmpty(point.color),
                source: nilIfEmpty(point.source)
            )
        }

        let sorted = sanitized.sorted { lhs, rhs in
            if lhs.startSec == rhs.startSec {
                return (lhs.index ?? Int.max) < (rhs.index ?? Int.max)
            }
            return lhs.startSec < rhs.startSec
        }

        var deduplicated: [ExternalDJCuePoint] = []
        for point in sorted {
            if let previous = deduplicated.last,
               abs(previous.startSec - point.startSec) < 0.001,
               previous.kind == point.kind,
               normalizedColor(previous.color) == normalizedColor(point.color),
               normalizedText(previous.name) == normalizedText(point.name) {
                continue
            }
            deduplicated.append(point)
        }

        return deduplicated.enumerated().map { index, point in
            ExternalDJCuePoint(
                kind: point.kind,
                name: point.name,
                index: point.index ?? index + 1,
                startSec: point.startSec,
                endSec: point.endSec,
                color: point.color,
                source: point.source
            )
        }
    }

    nonisolated func parseCueKind(_ value: String?) -> ExternalDJCuePoint.Kind {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "cue", "0x", "red", "blue", "cuepoint":
            return .cue
        case "1", "hot", "hotcue", "hot_cue", "hotcuepoint":
            return .hotcue
        case "2", "loop", "loopin", "loopout", "loop_in", "loop_out":
            return .loop
        default:
            return .unknown
        }
    }

    nonisolated func parseCueTime(_ value: Any?) -> Double? {
        if let number = value as? Double { return normalizedTime(number) }
        if let number = value as? Float { return normalizedTime(Double(number)) }
        if let number = value as? Int { return normalizedTime(Double(number)) }
        if let number = value as? Int64 { return normalizedTime(Double(number)) }
        if let number = value as? NSNumber { return normalizedTime(number.doubleValue) }
        guard let text = value as? String else { return nil }
        return normalizedTime(text)
    }

    nonisolated private func parseCueValue(
        _ value: String,
        kind: ExternalDJCuePoint.Kind,
        sourceName: String,
        startIndex: Int
    ) -> [ExternalDJCuePoint] {
        if let data = value.data(using: .utf8) {
            if let payload = parseJSONPayload(from: data) {
                return normalize(
                    payload
                        .compactMap { item -> ExternalDJCuePoint? in
                            let start = parseCueTime(item.start ?? item.time ?? item.duration)
                            guard let startSec = start else { return nil }
                            return ExternalDJCuePoint(
                                kind: parseCueKind(item.kind ?? kind.rawValue),
                                name: item.name,
                                index: item.index,
                                startSec: startSec,
                                endSec: parseCueTime(item.end),
                                color: item.color,
                                source: sourceName
                            )
                        }
                        .withStartOffset(startIndex: startIndex)
                )
            }

            if let object = (try? JSONSerialization.jsonObject(with: data)) {
                if let points = parseCuePointsFromJSONObject(object) {
                    return normalize(
                        points
                            .compactMap { point -> ExternalDJCuePoint? in
                                guard let start = parseCueTime(point["start"] ?? point["time"]) else { return nil }
                                return ExternalDJCuePoint(
                                    kind: parseCueKind(firstNonEmptyString(from: point, keys: ["type", "kind"])),
                                    name: firstNonEmptyString(from: point, keys: ["name", "label"]),
                                    index: parseInt(firstValue(from: point, keys: ["index", "idx", "number", "num"])),
                                    startSec: max(0, start),
                                    endSec: parseCueTime(point["end"]),
                                    color: firstNonEmptyString(from: point, keys: ["color", "colour"]),
                                    source: sourceName
                                )
                            }
                            .withStartOffset(startIndex: startIndex)
                    )
                }
            }
        }

        let tokens = splitCueText(value)
        guard !tokens.isEmpty else {
            return []
        }

        return normalize(
            tokens.enumerated().compactMap { offset, token in
                guard let startSec = parseCueTime(token) else { return nil }
                return ExternalDJCuePoint(
                    kind: kind,
                    name: nil,
                    index: startIndex + offset,
                    startSec: startSec,
                    endSec: nil,
                    color: nil,
                    source: sourceName
                )
            }
        )
    }

    nonisolated private func parseCuePointsPayload(from value: Any) -> [ParsedCuePoint]? {
        if let serialized = value as? String {
            let trimmed = serialized
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !trimmed.isEmpty else { return nil }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return parseCuePointsPayloadValues(from: object)
        }

        if let data = value as? Data {
            if let object = try? JSONSerialization.jsonObject(with: data) {
                return parseCuePointsPayloadValues(from: object)
            }
            if let text = String(data: data, encoding: .utf8) {
                return parseCuePointsPayloadValues(from: text)
            }
            return nil
        }

        return parseCuePointsPayloadValues(from: value)
    }

    nonisolated private func parseCuePointsPayloadValues(from value: Any) -> [ParsedCuePoint]? {
        if let points = value as? [[String: Any]] {
            return points.compactMap { parseParsedCuePoint(from: $0) }
        }

        if let dict = value as? [String: Any] {
            if let points = dict["points"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let points = dict["cues"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let points = dict["cue_points"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let points = dict["cuePoints"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let points = dict["hotcues"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let points = dict["hot_cues"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let points = dict["data"] as? [[String: Any]] { return points.compactMap { parseParsedCuePoint(from: $0) } }
            if let point = dict["cue"] as? [String: Any] { return [parseParsedCuePoint(from: point)].compactMap { $0 } }
            if let point = dict["hotcue"] as? [String: Any] { return [parseParsedCuePoint(from: point)].compactMap { $0 } }
        }

        return nil
    }

    nonisolated private func parseParsedCuePoint(from dict: [String: Any]) -> ParsedCuePoint? {
        ParsedCuePoint(
            kind: firstNonEmptyString(from: dict, keys: ["type", "kind"]),
            name: firstNonEmptyString(from: dict, keys: ["name", "label"]),
            index: parseInt(firstValue(from: dict, keys: ["index", "idx", "num", "number"])),
            start: parseCueTime(firstValue(from: dict, keys: ["start", "time"])),
            time: nil,
            end: parseCueTime(firstValue(from: dict, keys: ["end", "duration", "length"])),
            duration: nil,
            color: firstNonEmptyString(from: dict, keys: ["color", "colour"])
        )
    }

    nonisolated private func parseJSONPayload(from data: Data) -> [ParsedCuePoint]? {
        if let payload = try? JSONDecoder().decode([ParsedCuePoint].self, from: data) {
            return payload
        }
        if let payload = try? JSONDecoder().decode([String: [ParsedCuePoint]].self, from: data) {
            let keys = [
                "cues",
                "cuePoints",
                "hotcues",
                "hot_cues",
                "points",
                "cue_data",
                "hotcue_data",
                "cue_points",
                "cue_points_json"
            ]
            return firstParsedCuePoints(in: payload, keys: keys)
        }
        return nil
    }

    nonisolated private func parseCuePointsFromJSONObject(_ object: Any) -> [[String: Any]]? {
        if let points = object as? [[String: Any]] {
            return points
        }
        if let dict = object as? [String: Any] {
            let keys = [
                "cues",
                "cuePoints",
                "hotcues",
                "hot_cues",
                "points",
                "data",
                "markers"
            ]
            return firstCuePointDictionaryArray(in: dict, keys: keys)
        }
        return nil
    }

    nonisolated private func firstParsedCuePoints(
        in payload: [String: [ParsedCuePoint]],
        keys: [String]
    ) -> [ParsedCuePoint]? {
        for key in keys {
            if let points = payload[key] {
                return points
            }
        }
        return nil
    }

    nonisolated private func firstCuePointDictionaryArray(
        in dict: [String: Any],
        keys: [String]
    ) -> [[String: Any]]? {
        for key in keys {
            if let points = dict[key] as? [[String: Any]] {
                return points
            }
        }
        return nil
    }

    nonisolated private func normalizedTime(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains(":") {
            let components = cleaned.split(separator: ":").reversed().map(String.init)
            guard components.count <= 3 else { return nil }

            var seconds = 0.0
            for (index, token) in components.enumerated() {
                guard let value = Double(token) else { return nil }
                switch index {
                case 0:
                    seconds += value
                case 1:
                    seconds += value * 60
                default:
                    seconds += value * 3600
                }
            }
            return max(0, seconds)
        }

        guard let value = Double(cleaned) else { return nil }
        return normalizedTime(value)
    }

    nonisolated private func normalizedTime(_ value: Double) -> Double {
        if value >= 10_000 {
            return value / 1000.0
        }
        return max(0, value)
    }

    nonisolated private func splitCueText(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == ";" || $0 == "|" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private func firstNonEmptyString(from row: [String: Any?], keys: [String]) -> String? {
        let lookup = Dictionary(uniqueKeysWithValues: row.map { key, value in (key.lowercased(), value) })
        for key in keys {
            if let value = lookup[key.lowercased()], let text = parseString(value), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    nonisolated private func firstNonEmptyString(from row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key], let text = parseString(value), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    nonisolated private func firstValue(from row: [String: Any?], keys: [String]) -> Any? {
        let lookup = Dictionary(uniqueKeysWithValues: row.map { key, value in (key.lowercased(), value) })
        for key in keys {
            if let value = lookup[key.lowercased()] {
                return value
            }
        }
        return nil
    }

    nonisolated private func firstValue(from row: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = row[key] {
                return value
            }
        }
        return nil
    }

    nonisolated private func parseInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int { return intValue }
        if let intValue = value as? Int64 { return Int(intValue) }
        if let intValue = value as? Double { return Int(intValue) }
        if let intValue = value as? NSNumber { return Int(truncating: intValue) }
        if let intValue = value as? String {
            return Int(intValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated private func parseString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            return text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let dataValue = value as? Data {
            return String(data: dataValue, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let intValue = value as? Int64 { return String(intValue) }
        if let intValue = value as? Int { return String(intValue) }
        if let doubleValue = value as? Double { return String(doubleValue) }
        if let floatValue = value as? Float { return String(floatValue) }
        return nil
    }

    nonisolated private func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private func normalizedColor(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    nonisolated private func normalizedText(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

private extension Array where Element == ExternalDJCuePoint {
    nonisolated func withStartOffset(startIndex: Int) -> [ExternalDJCuePoint] {
        enumerated().map { index, point in
            ExternalDJCuePoint(
                kind: point.kind,
                name: point.name,
                index: point.index ?? startIndex + index,
                startSec: point.startSec,
                endSec: point.endSec,
                color: point.color,
                source: point.source
            )
        }
    }
}

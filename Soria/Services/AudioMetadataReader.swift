import AVFoundation
import Foundation

struct ExternalVisualizationSnapshot {
    var cuePoints: [ExternalDJCuePoint] = []
    var waveformPreview: [Double] = []

    nonisolated static let empty = ExternalVisualizationSnapshot()
}

struct ExternalVisualizationResolution {
    var metadata: [ExternalDJMetadata]
    var waveformPreview: [Double]
}

struct ExternalVisualizationResolver {
    private let cuePointParser = ExternalCuePointParser()

    nonisolated func enrich(trackPath: String, metadata: [ExternalDJMetadata]) async -> ExternalVisualizationResolution {
        var resolvedMetadata = metadata
        var waveformPreview: [Double] = []

        for index in resolvedMetadata.indices {
            let snapshot: ExternalVisualizationSnapshot
            switch resolvedMetadata[index].source {
            case .serato:
                let resolvedPath = TrackPathNormalizer.normalizedAbsolutePath(
                    resolvedMetadata[index].trackPath.isEmpty ? trackPath : resolvedMetadata[index].trackPath
                )
                guard !resolvedPath.isEmpty else { continue }
                snapshot = await readSeratoVisualization(trackURL: URL(fileURLWithPath: resolvedPath))
            case .rekordbox:
                guard let analysisPath = resolvedMetadata[index].analysisCachePath else { continue }
                let resolvedPath = TrackPathNormalizer.normalizedAbsolutePath(analysisPath)
                guard !resolvedPath.isEmpty else { continue }
                snapshot = readRekordboxVisualization(analysisURL: URL(fileURLWithPath: resolvedPath))
            }

            let mergedCuePoints = cuePointParser.normalize(
                resolvedMetadata[index].cuePoints + snapshot.cuePoints
            )
            if mergedCuePoints != resolvedMetadata[index].cuePoints {
                resolvedMetadata[index].cuePoints = mergedCuePoints
            }
            if !mergedCuePoints.isEmpty {
                resolvedMetadata[index].cueCount = max(resolvedMetadata[index].cueCount ?? 0, mergedCuePoints.count)
            }
            if snapshot.waveformPreview.count > waveformPreview.count {
                waveformPreview = snapshot.waveformPreview
            }
        }

        return ExternalVisualizationResolution(
            metadata: resolvedMetadata,
            waveformPreview: waveformPreview
        )
    }

    nonisolated func readSeratoVisualization(trackURL: URL) async -> ExternalVisualizationSnapshot {
        guard FileManager.default.fileExists(atPath: trackURL.path) else { return .empty }

        let asset = AVURLAsset(url: trackURL)
        var cuePoints: [ExternalDJCuePoint] = []
        var waveformPreview: [Double] = []

        let metadataFormats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in metadataFormats {
            let metadataItems = (try? await asset.loadMetadata(for: format)) ?? []
            for item in metadataItems {
                guard (item.key as? String) == "GEOB" else { continue }
                let extraAttributes = (try? await item.load(.extraAttributes)) ?? [:]
                guard let info = extraAttributes[AVMetadataExtraAttributeKey.info] as? String else { continue }
                guard let data = try? await item.load(.dataValue) else { continue }

                switch info {
                case "Serato Overview":
                    if waveformPreview.isEmpty {
                        waveformPreview = Self.parseSeratoOverviewTagData(data)
                    }
                case "Serato Markers2":
                    cuePoints.append(contentsOf: Self.parseSeratoMarkers2TagData(data))
                default:
                    continue
                }
            }
        }

        return ExternalVisualizationSnapshot(
            cuePoints: cuePointParser.normalize(cuePoints),
            waveformPreview: waveformPreview
        )
    }

    nonisolated func readRekordboxVisualization(analysisURL: URL) -> ExternalVisualizationSnapshot {
        var cuePoints: [ExternalDJCuePoint] = []
        var waveformPreview: [Double] = []

        for url in Self.rekordboxCompanionURLs(for: analysisURL) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }

            if waveformPreview.isEmpty {
                waveformPreview = Self.parseRekordboxWaveformPreviewFromAnalysisData(data)
            }
            cuePoints.append(contentsOf: Self.parseRekordboxCuePointsFromAnalysisData(data))
        }

        return ExternalVisualizationSnapshot(
            cuePoints: cuePointParser.normalize(cuePoints),
            waveformPreview: waveformPreview
        )
    }

    nonisolated static func parseSeratoOverviewTagData(_ data: Data) -> [Double] {
        guard data.count > 2 else { return [] }
        let payload = Array(data.dropFirst(2))
        var values: [Double] = []

        var offset = 0
        while offset + 16 <= payload.count {
            let row = payload[offset..<(offset + 16)]
            let peak = row.max() ?? 0
            values.append(Double(peak) / 255.0)
            offset += 16
        }

        return values
    }

    nonisolated static func parseSeratoMarkers2TagData(_ data: Data) -> [ExternalDJCuePoint] {
        guard data.count > 2 else { return [] }
        let encoded = seratoBase64Payload(from: data.dropFirst(2))
        guard !encoded.isEmpty else { return [] }
        guard let payload = Data(base64Encoded: encoded) else { return [] }
        guard payload.count >= 2 else { return [] }

        var offset = 2
        var cuePoints: [ExternalDJCuePoint] = []

        while offset < payload.count {
            guard let entryName = cString(in: payload, offset: &offset), !entryName.isEmpty else { break }
            guard let entryLength = bigEndianUInt32(in: payload, offset: offset) else { break }
            offset += 4
            guard entryLength > 0, offset + entryLength <= payload.count else { break }

            let entryData = payload.subdata(in: offset..<(offset + entryLength))
            offset += entryLength

            switch entryName {
            case "CUE":
                if let cuePoint = parseSeratoCueEntry(entryData) {
                    cuePoints.append(cuePoint)
                }
            case "LOOP":
                if let cuePoint = parseSeratoLoopEntry(entryData) {
                    cuePoints.append(cuePoint)
                }
            default:
                continue
            }
        }

        return ExternalCuePointParser().normalize(cuePoints)
    }

    nonisolated static func parseRekordboxCuePointsFromAnalysisData(_ data: Data) -> [ExternalDJCuePoint] {
        var cuePoints: [ExternalDJCuePoint] = []

        for chunk in rekordboxChunks(in: data) {
            switch chunk.id {
            case "PCOB":
                cuePoints.append(contentsOf: parseRekordboxCueTag(in: data, chunk: chunk, extended: false))
            case "PCO2":
                cuePoints.append(contentsOf: parseRekordboxCueTag(in: data, chunk: chunk, extended: true))
            default:
                continue
            }
        }

        return ExternalCuePointParser().normalize(cuePoints)
    }

    nonisolated static func parseRekordboxWaveformPreviewFromAnalysisData(_ data: Data) -> [Double] {
        let chunks = rekordboxChunks(in: data)

        if let chunk = chunks.first(where: { $0.id == "PWV2" }),
           let count = bigEndianUInt32(in: data, offset: chunk.offset + 12)
        {
            let values = bytes(in: data, start: chunk.offset + chunk.headerLength, count: min(count, chunk.totalLength - chunk.headerLength))
            return normalizeWaveform(values) { Double($0) / 31.0 }
        }

        if let chunk = chunks.first(where: { $0.id == "PWAV" }) {
            let values = bytes(in: data, start: chunk.offset + chunk.headerLength, count: chunk.totalLength - chunk.headerLength)
            let waveform = normalizeWaveform(values) { Double($0 & 0x1f) / 31.0 }
            if waveform.contains(where: { $0 > 0 }) {
                return waveform
            }
            return normalizeWaveform(values) { Double($0) / 255.0 }
        }

        return []
    }

    nonisolated private static func parseSeratoCueEntry(_ data: Data) -> ExternalDJCuePoint? {
        guard data.count >= 13 else { return nil }
        guard let positionMs = bigEndianUInt32(in: data, offset: 2) else { return nil }

        let rawIndex = Int(data[1])
        let cueKind: ExternalDJCuePoint.Kind = rawIndex == 0 ? .cue : .hotcue
        let color = data.count >= 10 ? colorHex(red: data[7], green: data[8], blue: data[9]) : nil
        let name = trailingNullTerminatedString(in: data, offset: 12)

        return ExternalDJCuePoint(
            kind: cueKind,
            name: name,
            index: rawIndex == 0 ? nil : rawIndex,
            startSec: Double(positionMs) / 1000.0,
            endSec: nil,
            color: color,
            source: "serato:markers2"
        )
    }

    nonisolated private static func parseSeratoLoopEntry(_ data: Data) -> ExternalDJCuePoint? {
        guard data.count >= 21 else { return nil }
        guard let startPositionMs = bigEndianUInt32(in: data, offset: 2) else { return nil }
        guard let endPositionMs = bigEndianUInt32(in: data, offset: 6) else { return nil }

        return ExternalDJCuePoint(
            kind: .loop,
            name: trailingNullTerminatedString(in: data, offset: 20),
            index: Int(data[1]),
            startSec: Double(startPositionMs) / 1000.0,
            endSec: Double(endPositionMs) / 1000.0,
            color: nil,
            source: "serato:markers2"
        )
    }

    nonisolated private static func parseRekordboxCueTag(
        in data: Data,
        chunk: RekordboxChunk,
        extended: Bool
    ) -> [ExternalDJCuePoint] {
        let countOffset = chunk.offset + (extended ? 16 : 18)
        guard let cueCount = bigEndianUInt16(in: data, offset: countOffset) else { return [] }

        var cuePoints: [ExternalDJCuePoint] = []
        var entryOffset = chunk.offset + chunk.headerLength
        let expectedMagic = extended ? "PCP2" : "PCPT"

        for _ in 0..<cueCount {
            guard asciiString(in: data, offset: entryOffset, length: 4) == expectedMagic else { break }
            guard let entryLength = bigEndianUInt32(in: data, offset: entryOffset + 8) else { break }
            guard entryLength > 0, entryOffset + entryLength <= data.count else { break }

            let point: ExternalDJCuePoint?
            if extended {
                point = parseRekordboxExtendedCueEntry(in: data, offset: entryOffset, entryLength: entryLength)
            } else {
                point = parseRekordboxCueEntry(in: data, offset: entryOffset, entryLength: entryLength)
            }

            if let point {
                cuePoints.append(point)
            }
            entryOffset += entryLength
        }

        return cuePoints
    }

    nonisolated private static func parseRekordboxCueEntry(
        in data: Data,
        offset: Int,
        entryLength: Int
    ) -> ExternalDJCuePoint? {
        guard entryLength >= 40 else { return nil }
        guard let hotCue = bigEndianUInt32(in: data, offset: offset + 12) else { return nil }
        guard let timeMs = bigEndianUInt32(in: data, offset: offset + 32) else { return nil }
        let loopTimeMs = bigEndianUInt32(in: data, offset: offset + 36) ?? 0
        let isLoop = loopTimeMs > timeMs

        return ExternalDJCuePoint(
            kind: isLoop ? .loop : (hotCue > 0 ? .hotcue : .cue),
            name: nil,
            index: hotCue > 0 ? hotCue : nil,
            startSec: Double(timeMs) / 1000.0,
            endSec: isLoop ? Double(loopTimeMs) / 1000.0 : nil,
            color: nil,
            source: "rekordbox:anlz"
        )
    }

    nonisolated private static func parseRekordboxExtendedCueEntry(
        in data: Data,
        offset: Int,
        entryLength: Int
    ) -> ExternalDJCuePoint? {
        guard entryLength >= 40 else { return nil }
        guard let hotCue = bigEndianUInt32(in: data, offset: offset + 12) else { return nil }
        guard let timeMs = bigEndianUInt32(in: data, offset: offset + 20) else { return nil }
        let loopTimeMs = bigEndianUInt32(in: data, offset: offset + 24) ?? 0
        let isLoop = loopTimeMs > timeMs
        let commentLength = bigEndianUInt32(in: data, offset: offset + 40) ?? 0
        let commentStart = offset + 44

        var comment: String?
        if commentLength > 0, commentStart + commentLength <= data.count {
            let commentData = data.subdata(in: commentStart..<(commentStart + commentLength))
            comment = decodeUTF16String(commentData)
        }

        var color: String?
        let colorOffset = commentStart + commentLength + 1
        if colorOffset + 2 < offset + entryLength {
            color = colorHex(
                red: data[colorOffset],
                green: data[colorOffset + 1],
                blue: data[colorOffset + 2]
            )
        }

        return ExternalDJCuePoint(
            kind: isLoop ? .loop : (hotCue > 0 ? .hotcue : .cue),
            name: comment,
            index: hotCue > 0 ? hotCue : nil,
            startSec: Double(timeMs) / 1000.0,
            endSec: isLoop ? Double(loopTimeMs) / 1000.0 : nil,
            color: color,
            source: "rekordbox:anlz_ext"
        )
    }

    nonisolated private static func normalizeWaveform(_ bytes: [UInt8], transform: (UInt8) -> Double) -> [Double] {
        bytes.map { value in
            let normalized = transform(value)
            return max(0.0, min(1.0, normalized))
        }
    }

    nonisolated private static func seratoBase64Payload(from data: Data.SubSequence) -> String {
        var encoded = ""
        for byte in data {
            if byte == 0 { break }
            let scalar = UnicodeScalar(byte)
            let character = Character(scalar)
            if "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".contains(character) {
                encoded.append(character)
            }
        }
        while encoded.count % 4 != 0 {
            encoded.append("=")
        }
        return encoded
    }

    nonisolated private static func trailingNullTerminatedString(in data: Data, offset: Int) -> String? {
        guard offset < data.count else { return nil }
        let trailing = data[offset...]
        let nameBytes = trailing.prefix { $0 != 0 }
        guard !nameBytes.isEmpty else { return nil }
        return String(decoding: nameBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()
    }

    nonisolated private static func decodeUTF16String(_ data: Data) -> String? {
        String(data: data, encoding: .utf16BigEndian)?
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()
    }

    nonisolated private static func rekordboxCompanionURLs(for analysisURL: URL) -> [URL] {
        let baseURL = analysisURL.deletingPathExtension()
        var seen = Set<String>()
        return ["DAT", "EXT", "2EX", "3EX"].compactMap { ext in
            let url = baseURL.appendingPathExtension(ext)
            if seen.insert(url.path).inserted {
                return url
            }
            return nil
        }
    }

    nonisolated private static func rekordboxChunks(in data: Data) -> [RekordboxChunk] {
        guard asciiString(in: data, offset: 0, length: 4) == "PMAI" else { return [] }
        guard let headerLength = bigEndianUInt32(in: data, offset: 4), headerLength > 0, headerLength < data.count else {
            return []
        }

        var chunks: [RekordboxChunk] = []
        var offset = headerLength
        while offset + 12 <= data.count {
            guard let identifier = asciiString(in: data, offset: offset, length: 4) else { break }
            guard let chunkHeaderLength = bigEndianUInt32(in: data, offset: offset + 4) else { break }
            guard let totalLength = bigEndianUInt32(in: data, offset: offset + 8) else { break }
            guard chunkHeaderLength > 0, totalLength >= chunkHeaderLength, offset + totalLength <= data.count else { break }

            chunks.append(
                RekordboxChunk(
                    id: identifier,
                    offset: offset,
                    headerLength: chunkHeaderLength,
                    totalLength: totalLength
                )
            )
            offset += totalLength
        }

        return chunks
    }

    nonisolated private static func asciiString(in data: Data, offset: Int, length: Int) -> String? {
        guard offset >= 0, length > 0, offset + length <= data.count else { return nil }
        return String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii)
    }

    nonisolated private static func bytes(in data: Data, start: Int, count: Int) -> [UInt8] {
        guard start >= 0, count > 0, start + count <= data.count else { return [] }
        return Array(data[start..<(start + count)])
    }

    nonisolated private static func bigEndianUInt16(in data: Data, offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return Int(data[offset]) << 8 | Int(data[offset + 1])
    }

    nonisolated private static func bigEndianUInt32(in data: Data, offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return Int(data[offset]) << 24
            | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8
            | Int(data[offset + 3])
    }

    nonisolated private static func cString(in data: Data, offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        let start = offset
        while offset < data.count, data[offset] != 0 {
            offset += 1
        }
        guard offset < data.count else { return nil }
        let value = String(decoding: data[start..<offset], as: UTF8.self)
        offset += 1
        return value
    }

    nonisolated private static func colorHex(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

enum AudioMetadataReader {
    static func readMetadata(for url: URL) async -> (title: String, artist: String, album: String, genre: String, duration: TimeInterval, sampleRate: Double, bpm: Double?, musicalKey: String?) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var genre = ""
        var bpm: Double?
        var musicalKey: String?

        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in commonMetadata {
            guard let key = item.commonKey?.rawValue else { continue }
            let value = (try? await item.load(.stringValue)) ?? ""
            switch key {
            case "title": title = value
            case "artist": artist = value
            case "albumName": album = value
            case "type": genre = value
            default: break
            }
        }

        let metadataFormats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in metadataFormats {
            let metadataItems = (try? await asset.loadMetadata(for: format)) ?? []
            for item in metadataItems {
                let key = item.commonKey?.rawValue.lowercased() ?? ""
                let value = (try? await item.load(.stringValue)) ?? ""
                if bpm == nil, key.contains("bpm") || value.lowercased().contains("bpm") {
                    bpm = Double(value.filter { "0123456789.".contains($0) })
                }
                if musicalKey == nil, key.contains("key") {
                    musicalKey = value
                }
            }
        }

        let sampleRate = sampleRateFromFile(url) ?? 0
        return (title, artist, album, genre, duration.isFinite ? duration : 0, sampleRate, bpm, musicalKey)
    }

    private static func sampleRateFromFile(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return file.processingFormat.sampleRate
    }
}

private struct RekordboxChunk {
    let id: String
    let offset: Int
    let headerLength: Int
    let totalLength: Int
}

private extension String {
    nonisolated func nilIfEmpty() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation
import Testing
@testable import Soria

@Suite(.serialized)
struct PlaylistExportServiceTests {
    @Test func rekordboxPlaylistM3U8ExportSkipsMissingAndDuplicatePaths() throws {
        let directory = try makeExportTemporaryDirectory()
        let trackOneURL = directory.appendingPathComponent("Music/Alpha Track.mp3")
        let trackTwoURL = directory.appendingPathComponent("Music/도시 Pop.aiff")
        try createFile(at: trackOneURL)
        try createFile(at: trackTwoURL)

        let missingURL = directory.appendingPathComponent("Music/Missing.mp3")
        let trackOne = makeExportTrack(path: trackOneURL.path, title: "Alpha Track", artist: "DJ Alpha")
        let duplicateTrack = makeExportTrack(path: trackOneURL.path, title: "Alpha Duplicate")
        let missingTrack = makeExportTrack(path: missingURL.path, title: "Missing")
        let trackTwo = makeExportTrack(path: trackTwoURL.path, title: "도시 Pop", artist: "Seoul")

        let service = PlaylistExportService(
            preflight: VendorExportPreflight(
                fileManager: .default,
                runningApplicationTokensProvider: { [] }
            )
        )
        let result = try service.export(
            playlistName: "Warmup Set",
            tracks: [trackOne, duplicateTrack, missingTrack, trackTwo],
            target: .rekordboxPlaylistM3U8,
            outputDirectory: directory,
            librarySources: [stubLibrarySource(kind: .rekordbox, resolvedPath: directory.path)]
        )

        let playlistURL = directory.appendingPathComponent("Warmup Set.m3u8")
        let contents = try String(contentsOf: playlistURL, encoding: .utf8)

        #expect(result.outputPaths == [playlistURL.path])
        #expect(contents.contains("#EXTM3U"))
        #expect(contents.contains(trackOneURL.path))
        #expect(contents.contains(trackTwoURL.path))
        #expect(!contents.contains(missingURL.path))
        #expect(contents.range(of: trackOneURL.path)?.lowerBound ?? contents.startIndex < contents.range(of: trackTwoURL.path)?.lowerBound ?? contents.endIndex)
        #expect(result.warnings.count == 2)
        #expect(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("duplicate") }))
        #expect(result.warnings.contains(where: { $0.localizedCaseInsensitiveContains("missing") }))
        #expect(result.destinationDescription.localizedCaseInsensitiveContains("import playlist"))
    }

    @Test func rekordboxXMLExportProducesLocationKeyXMLAndRoundTripsMemberships() throws {
        let directory = try makeExportTemporaryDirectory()
        let trackOneURL = directory.appendingPathComponent("Music/Festival Intro.mp3")
        let trackTwoURL = directory.appendingPathComponent("Music/Sunrise Tool.wav")
        try createFile(at: trackOneURL)
        try createFile(at: trackTwoURL)

        let service = PlaylistExportService(
            preflight: VendorExportPreflight(
                fileManager: .default,
                runningApplicationTokensProvider: { [] }
            )
        )
        let result = try service.export(
            playlistName: "Festival / Day 1 / Sunrise",
            tracks: [
                makeExportTrack(path: trackOneURL.path, title: "Festival Intro", artist: "Soria", bpm: 122, musicalKey: "8A"),
                makeExportTrack(path: trackTwoURL.path, title: "Sunrise Tool", artist: "Soria", bpm: 124, musicalKey: "9A"),
            ],
            target: .rekordboxLibraryXML,
            outputDirectory: directory,
            librarySources: [stubLibrarySource(kind: .rekordbox, resolvedPath: directory.path)]
        )

        let xmlURL = directory.appendingPathComponent("Festival - Day 1 - Sunrise.xml")
        let xml = try String(contentsOf: xmlURL, encoding: .utf8)
        let parsed = try RekordboxXMLParser().parse(from: xmlURL)

        #expect(result.outputPaths == [xmlURL.path])
        #expect(xml.contains("<PRODUCT Name=\"Soria\""))
        #expect(xml.contains("KeyType=\"1\""))
        #expect(xml.contains("Count=\"1\""))
        #expect(xml.contains("TrackID=\"1\""))
        #expect(xml.contains("file://localhost"))
        #expect(parsed.memberships(forTrackPath: trackOneURL.path) == ["Festival / Day 1 / Sunrise"])
        #expect(parsed.memberships(forTrackPath: trackTwoURL.path) == ["Festival / Day 1 / Sunrise"])
        #expect(parsed.trackPathsByID["1"] == trackOneURL.path)
        #expect(parsed.trackPathsByID["2"] == trackTwoURL.path)
    }

    @Test func seratoCrateWriterSerializesTracksAndBacksUpOverwrite() throws {
        let directory = try makeExportTemporaryDirectory()
        let driveRoot = directory.appendingPathComponent("Drive", isDirectory: true)
        let cratesRoot = driveRoot.appendingPathComponent("_Serato_", isDirectory: true)
        let subcratesURL = cratesRoot.appendingPathComponent("Subcrates", isDirectory: true)
        try FileManager.default.createDirectory(at: subcratesURL, withIntermediateDirectories: true)

        let trackOneURL = driveRoot.appendingPathComponent("Music/One.mp3")
        let trackTwoURL = driveRoot.appendingPathComponent("Music/Sub/두번째.aiff")
        try createFile(at: trackOneURL)
        try createFile(at: trackTwoURL)

        let existingCrateURL = subcratesURL.appendingPathComponent("Digging%%Warmup.crate")
        try Data("legacy".utf8).write(to: existingCrateURL)

        let writer = SeratoCrateWriter(fileManager: .default)
        let result = try writer.write(
            playlistName: "Digging / Warmup",
            tracks: [
                VendorExportTrack(track: makeExportTrack(path: trackOneURL.path, title: "One"), normalizedPath: trackOneURL.path),
                VendorExportTrack(track: makeExportTrack(path: trackTwoURL.path, title: "두번째"), normalizedPath: trackTwoURL.path),
            ],
            cratesRoot: cratesRoot
        )

        let crateData = try Data(contentsOf: result.crateURL)
        let topLevelRecords = parseCrateRecords(crateData)
        let trackRecords = topLevelRecords.filter { $0.tag == "otrk" }
        let ptrkValues = trackRecords.compactMap { record -> String? in
            let nested = parseCrateRecords(record.payload)
            guard let ptrk = nested.first(where: { $0.tag == "ptrk" }) else { return nil }
            return decodeUTF16BigEndian(ptrk.payload)
        }

        #expect(result.crateURL.lastPathComponent == "Digging%%Warmup.crate")
        #expect(result.backupURL != nil)
        #expect(result.backupURL.flatMap { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(topLevelRecords.first?.tag == "vrsn")
        #expect(trackRecords.count == 2)
        #expect(ptrkValues == ["Music/One.mp3", "Music/Sub/두번째.aiff"])
    }
}

private struct ParsedCrateRecord: Equatable {
    let tag: String
    let payload: Data
}

private func parseCrateRecords(_ data: Data) -> [ParsedCrateRecord] {
    var records: [ParsedCrateRecord] = []
    var cursor = 0

    while cursor + 8 <= data.count {
        let tagData = data.subdata(in: cursor..<(cursor + 4))
        let lengthData = data.subdata(in: (cursor + 4)..<(cursor + 8))
        let length = lengthData.withUnsafeBytes { rawBuffer -> UInt32 in
            rawBuffer.load(as: UInt32.self).bigEndian
        }

        let payloadStart = cursor + 8
        let payloadEnd = payloadStart + Int(length)
        guard payloadEnd <= data.count else { break }

        let payload = data.subdata(in: payloadStart..<payloadEnd)
        let tag = String(decoding: tagData, as: UTF8.self)
        records.append(ParsedCrateRecord(tag: tag, payload: payload))
        cursor = payloadEnd
    }

    return records
}

private func decodeUTF16BigEndian(_ data: Data) -> String {
    var codeUnits: [UInt16] = []
    codeUnits.reserveCapacity(data.count / 2)

    var index = data.startIndex
    while index + 1 < data.endIndex {
        let value = data[index...index + 1].withUnsafeBytes { rawBuffer -> UInt16 in
            rawBuffer.load(as: UInt16.self).bigEndian
        }
        codeUnits.append(value)
        index += 2
    }

    return String(decoding: codeUnits, as: UTF16.self)
}

private func makeExportTrack(
    path: String,
    title: String,
    artist: String = "",
    bpm: Double? = nil,
    musicalKey: String? = nil
) -> Track {
    Track(
        id: UUID(),
        filePath: path,
        fileName: URL(fileURLWithPath: path).lastPathComponent,
        title: title,
        artist: artist,
        album: "",
        genre: "",
        duration: 180,
        sampleRate: 44_100,
        bpm: bpm,
        musicalKey: musicalKey,
        modifiedTime: Date(timeIntervalSince1970: 1_700_000_000),
        contentHash: UUID().uuidString,
        analyzedAt: nil,
        embeddingProfileID: nil,
        embeddingUpdatedAt: nil,
        hasSeratoMetadata: false,
        hasRekordboxMetadata: false,
        bpmSource: nil,
        keySource: nil
    )
}

private func makeExportTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Soria-Export-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func createFile(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
}

private func stubLibrarySource(kind: LibrarySourceKind, resolvedPath: String?) -> LibrarySourceRecord {
    LibrarySourceRecord(
        id: UUID(),
        kind: kind,
        enabled: true,
        resolvedPath: resolvedPath,
        lastSyncAt: nil,
        status: resolvedPath == nil ? .missing : .available,
        lastError: nil
    )
}

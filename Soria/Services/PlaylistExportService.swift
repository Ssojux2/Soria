import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case rekordboxXML = "Rekordbox XML"
    case seratoSafePackage = "Serato Safe Package"

    var id: String { rawValue }
}

final class PlaylistExportService {
    func export(
        playlistName: String,
        tracks: [Track],
        format: ExportFormat,
        outputDirectory: URL
    ) throws -> ExportJobResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        switch format {
        case .rekordboxXML:
            return try exportRekordboxXML(playlistName: playlistName, tracks: tracks, outputDirectory: outputDirectory)
        case .seratoSafePackage:
            return try exportSeratoSafePackage(playlistName: playlistName, tracks: tracks, outputDirectory: outputDirectory)
        }
    }

    private func exportRekordboxXML(playlistName: String, tracks: [Track], outputDirectory: URL) throws -> ExportJobResult {
        let fileURL = outputDirectory.appendingPathComponent("\(playlistName).xml")
        var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        body += "<DJ_PLAYLISTS Version=\"1.0.0\">\n"
        body += "  <COLLECTION Entries=\"\(tracks.count)\">\n"
        for track in tracks {
            let location = fileURLString(for: track.filePath)
            body += "    <TRACK TrackID=\"\(track.id.uuidString)\" Name=\"\(xmlEscaped(track.title))\" Artist=\"\(xmlEscaped(track.artist))\" Genre=\"\(xmlEscaped(track.genre))\" Location=\"\(location)\" AverageBpm=\"\(track.bpm ?? 0)\" Tonality=\"\(xmlEscaped(track.musicalKey ?? ""))\"/>\n"
        }
        body += "  </COLLECTION>\n"
        body += "  <PLAYLISTS>\n"
        body += "    <NODE Type=\"0\" Name=\"ROOT\">\n"
        body += "      <NODE Type=\"1\" Name=\"\(xmlEscaped(playlistName))\" Entries=\"\(tracks.count)\">\n"
        for track in tracks {
            body += "        <TRACK Key=\"\(track.id.uuidString)\"/>\n"
        }
        body += "      </NODE>\n"
        body += "    </NODE>\n"
        body += "  </PLAYLISTS>\n"
        body += "</DJ_PLAYLISTS>\n"
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        return ExportJobResult(outputPaths: [fileURL.path], message: "Rekordbox XML export complete")
    }

    private func exportSeratoSafePackage(playlistName: String, tracks: [Track], outputDirectory: URL) throws -> ExportJobResult {
        // 한국어: Serato 직접 쓰기는 위험하므로 안전 패키지(m3u/csv/txt)만 생성합니다.
        let m3uURL = outputDirectory.appendingPathComponent("\(playlistName).m3u")
        let csvURL = outputDirectory.appendingPathComponent("\(playlistName)-ranked.csv")
        let readmeURL = outputDirectory.appendingPathComponent("\(playlistName)-serato-import.txt")

        let m3u = tracks.map { $0.filePath }.joined(separator: "\n") + "\n"
        try m3u.write(to: m3uURL, atomically: true, encoding: .utf8)

        var csv = "rank,title,artist,bpm,key,genre,path\n"
        for (idx, track) in tracks.enumerated() {
            csv += "\(idx + 1),\(csvEscaped(track.title)),\(csvEscaped(track.artist)),\(track.bpm ?? 0),\(csvEscaped(track.musicalKey ?? "")),\(csvEscaped(track.genre)),\(csvEscaped(track.filePath))\n"
        }
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let guide = """
        Serato Safe Import Package
        1) Open Serato DJ Pro.
        2) Drag the generated .m3u file into your Crates panel.
        3) Use the CSV for score/metadata reference.
        """
        try guide.write(to: readmeURL, atomically: true, encoding: .utf8)

        return ExportJobResult(
            outputPaths: [m3uURL.path, csvURL.path, readmeURL.path],
            message: "Serato safe package export complete (non-destructive)"
        )
    }

    private func xmlEscaped(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func csvEscaped(_ input: String) -> String {
        let escaped = input.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func fileURLString(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.absoluteString.replacingOccurrences(of: "file://", with: "file://localhost")
    }
}

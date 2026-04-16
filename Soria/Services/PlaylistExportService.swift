import Foundation

enum ExportTarget: String, CaseIterable, Identifiable {
    case rekordboxPlaylistM3U8 = "rekordbox_playlist_m3u8"
    case rekordboxLibraryXML = "rekordbox_library_xml"
    case seratoCrate = "serato_crate"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rekordboxPlaylistM3U8:
            return "rekordbox 6/7 Playlist"
        case .rekordboxLibraryXML:
            return "rekordbox XML"
        case .seratoCrate:
            return "Serato Crate"
        }
    }

    var shortLabel: String {
        switch self {
        case .rekordboxPlaylistM3U8:
            return "RB Playlist"
        case .rekordboxLibraryXML:
            return "RB XML"
        case .seratoCrate:
            return "Serato"
        }
    }

    var helperText: String {
        switch self {
        case .rekordboxPlaylistM3U8:
            return "Exports a UTF-8 .m3u8 file for rekordbox 6/7 File > Import > Import Playlist."
        case .rekordboxLibraryXML:
            return "Exports a rekordbox-compatible library XML for the Imported Library / Bridge flow."
        case .seratoCrate:
            return "Writes a .crate file directly into the detected _Serato_/Subcrates folder."
        }
    }

    var defaultFileExtension: String {
        switch self {
        case .rekordboxPlaylistM3U8:
            return "m3u8"
        case .rekordboxLibraryXML:
            return "xml"
        case .seratoCrate:
            return "crate"
        }
    }

    var requiresExplicitOutputDirectory: Bool {
        self != .seratoCrate
    }
}

enum PlaylistExportError: LocalizedError {
    case invalidPlaylistName
    case missingOutputDirectory
    case noTracksToExport
    case noValidTracksToExport
    case seratoCratesRootUnavailable
    case multipleSeratoRoots([String])

    var errorDescription: String? {
        switch self {
        case .invalidPlaylistName:
            return "Enter a playlist name before exporting."
        case .missingOutputDirectory:
            return "Choose an export destination folder first."
        case .noTracksToExport:
            return "Add at least one playlist track before exporting."
        case .noValidTracksToExport:
            return "No valid local files were available to export."
        case .seratoCratesRootUnavailable:
            return "Could not find a writable _Serato_ root for the selected tracks."
        case .multipleSeratoRoots(let roots):
            let joined = roots.joined(separator: ", ")
            return "The selected tracks span multiple Serato roots. Export one drive at a time. Roots: \(joined)"
        }
    }
}

enum VendorPlaylistNaming {
    nonisolated static func components(for playlistName: String) -> [String] {
        playlistName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func logicalPlaylistName(from input: String) -> String {
        let components = components(for: input)
        return components.isEmpty ? "" : components.joined(separator: " / ")
    }

    nonisolated static func fileSystemSafeBaseName(for playlistName: String) -> String {
        let normalized = logicalPlaylistName(from: playlistName)
        guard !normalized.isEmpty else { return "" }

        return normalized
            .replacingOccurrences(of: " / ", with: " - ")
            .replacingOccurrences(of: "/", with: " - ")
            .replacingOccurrences(of: ":", with: " - ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func seratoCrateFileName(for playlistName: String) -> String {
        let parts = components(for: playlistName).map(seratoSafeComponent(_:))
        let fallback = seratoSafeComponent(fileSystemSafeBaseName(for: playlistName))
        let baseName = parts.isEmpty ? fallback : parts.joined(separator: "%%")
        return "\(baseName).crate"
    }

    nonisolated private static func seratoSafeComponent(_ input: String) -> String {
        let collapsed = input
            .replacingOccurrences(of: ":", with: " - ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Playlist" : collapsed
    }
}

final class PlaylistExportService {
    private let fileManager: FileManager
    private let preflight: VendorExportPreflight
    private let rekordboxPlaylistWriter: RekordboxPlaylistWriter
    private let rekordboxXMLWriter: RekordboxXMLWriter
    private let seratoCrateWriter: SeratoCrateWriter

    init(
        fileManager: FileManager = .default,
        preflight: VendorExportPreflight? = nil,
        rekordboxPlaylistWriter: RekordboxPlaylistWriter = RekordboxPlaylistWriter(),
        rekordboxXMLWriter: RekordboxXMLWriter = RekordboxXMLWriter(),
        seratoCrateWriter: SeratoCrateWriter? = nil
    ) {
        self.fileManager = fileManager
        self.preflight = preflight ?? VendorExportPreflight(fileManager: fileManager)
        self.rekordboxPlaylistWriter = rekordboxPlaylistWriter
        self.rekordboxXMLWriter = rekordboxXMLWriter
        self.seratoCrateWriter = seratoCrateWriter ?? SeratoCrateWriter(fileManager: fileManager)
    }

    func detectTargets(librarySources: [LibrarySourceRecord] = []) -> DetectedVendorTargets {
        preflight.detectTargets(librarySources: librarySources)
    }

    func export(
        playlistName: String,
        tracks: [Track],
        target: ExportTarget,
        outputDirectory: URL? = nil,
        librarySources: [LibrarySourceRecord] = []
    ) throws -> ExportJobResult {
        guard !tracks.isEmpty else {
            throw PlaylistExportError.noTracksToExport
        }

        let prepared = try preflight.prepare(
            playlistName: playlistName,
            tracks: tracks,
            target: target,
            librarySources: librarySources
        )

        switch target {
        case .rekordboxPlaylistM3U8:
            guard let outputDirectory else {
                throw PlaylistExportError.missingOutputDirectory
            }
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let outputURL = outputDirectory
                .appendingPathComponent(prepared.safeFileBaseName)
                .appendingPathExtension(target.defaultFileExtension)
            let writtenURL = try rekordboxPlaylistWriter.write(
                playlistName: prepared.playlistName,
                tracks: prepared.tracks,
                to: outputURL
            )
            return ExportJobResult(
                outputPaths: [writtenURL.path],
                message: "rekordbox playlist export complete",
                destinationDescription: "Import in rekordbox 6/7 using File > Import > Import Playlist.",
                warnings: prepared.warnings
            )

        case .rekordboxLibraryXML:
            guard let outputDirectory else {
                throw PlaylistExportError.missingOutputDirectory
            }
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let outputURL = outputDirectory
                .appendingPathComponent(prepared.safeFileBaseName)
                .appendingPathExtension(target.defaultFileExtension)
            let writtenURL = try rekordboxXMLWriter.write(
                playlistName: prepared.playlistName,
                tracks: prepared.tracks,
                to: outputURL
            )
            return ExportJobResult(
                outputPaths: [writtenURL.path],
                message: "rekordbox XML export complete",
                destinationDescription: "Select this XML file from rekordbox Preferences > Bridge > Imported Library.",
                warnings: prepared.warnings
            )

        case .seratoCrate:
            guard let cratesRoot = prepared.seratoCratesRoot else {
                throw PlaylistExportError.seratoCratesRootUnavailable
            }
            let subcratesPath = cratesRoot.appendingPathComponent("Subcrates", isDirectory: true).path
            let writeResult = try seratoCrateWriter.write(
                playlistName: prepared.playlistName,
                tracks: prepared.tracks,
                cratesRoot: cratesRoot
            )

            var outputPaths = [writeResult.crateURL.path]
            if let backupURL = writeResult.backupURL {
                outputPaths.append(backupURL.path)
            }

            return ExportJobResult(
                outputPaths: outputPaths,
                message: "Serato crate export complete (experimental)",
                destinationDescription: "Crate written directly to \(subcratesPath).",
                warnings: prepared.warnings
            )
        }
    }
}

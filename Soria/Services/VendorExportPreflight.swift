import AppKit
import Foundation

struct VendorExportTrack: Hashable {
    let track: Track
    let normalizedPath: String

    var rekordboxLocation: String {
        let url = URL(fileURLWithPath: normalizedPath)
        return url.absoluteString.replacingOccurrences(of: "file://", with: "file://localhost")
    }
}

struct PreparedVendorExport {
    let playlistName: String
    let safeFileBaseName: String
    let tracks: [VendorExportTrack]
    let warnings: [String]
    let detectedTargets: DetectedVendorTargets
    let seratoCratesRoot: URL?
}

struct VendorExportPreflight {
    private let fileManager: FileManager
    private let rekordboxLibraryService: RekordboxLibraryService
    private let seratoLibraryService: SeratoLibraryService
    private let runningApplicationTokensProvider: () -> [String]

    init(
        fileManager: FileManager = .default,
        rekordboxLibraryService: RekordboxLibraryService = RekordboxLibraryService(),
        seratoLibraryService: SeratoLibraryService = SeratoLibraryService(),
        runningApplicationTokensProvider: @escaping () -> [String] = {
            NSWorkspace.shared.runningApplications.flatMap { application in
                [application.localizedName, application.bundleIdentifier].compactMap { $0 }
            }
        }
    ) {
        self.fileManager = fileManager
        self.rekordboxLibraryService = rekordboxLibraryService
        self.seratoLibraryService = seratoLibraryService
        self.runningApplicationTokensProvider = runningApplicationTokensProvider
    }

    func detectTargets(librarySources: [LibrarySourceRecord] = []) -> DetectedVendorTargets {
        let rekordboxSettingsPath = rekordboxLibraryService.defaultSettingsURL()?.path
        let rekordboxLibraryDirectory = librarySources
            .first(where: { $0.kind == .rekordbox })?
            .resolvedPath
            ?? (try? rekordboxLibraryService.defaultDatabaseDirectory()?.path)

        let seratoDatabasePath = librarySources
            .first(where: { $0.kind == .serato })?
            .resolvedPath
            ?? seratoLibraryService.defaultDatabaseURL()?.path

        let seratoCratesRoot = preferredDefaultSeratoCratesRoot()?.path

        return DetectedVendorTargets(
            rekordboxLibraryDirectory: rekordboxLibraryDirectory,
            rekordboxSettingsPath: rekordboxSettingsPath,
            seratoDatabasePath: seratoDatabasePath,
            seratoCratesRoot: seratoCratesRoot
        )
    }

    func prepare(
        playlistName: String,
        tracks: [Track],
        target: ExportTarget,
        librarySources: [LibrarySourceRecord] = [],
        detectedTargetsOverride: DetectedVendorTargets? = nil
    ) throws -> PreparedVendorExport {
        let normalizedPlaylistName = VendorPlaylistNaming.logicalPlaylistName(from: playlistName)
        guard !normalizedPlaylistName.isEmpty else {
            throw PlaylistExportError.invalidPlaylistName
        }

        let safeFileBaseName = VendorPlaylistNaming.fileSystemSafeBaseName(for: normalizedPlaylistName)
        guard !safeFileBaseName.isEmpty else {
            throw PlaylistExportError.invalidPlaylistName
        }

        let detectedTargets = detectedTargetsOverride ?? detectTargets(librarySources: librarySources)
        let preparedTracks = preparedTracks(from: tracks)
        guard !preparedTracks.tracks.isEmpty else {
            throw PlaylistExportError.noValidTracksToExport
        }

        var warnings = preparedTracks.warnings
        var seratoCratesRoot: URL?

        switch target {
        case .rekordboxPlaylistM3U8, .rekordboxLibraryXML:
            if !detectedTargets.hasRekordboxInstallation {
                warnings.append("rekordbox 6/7 was not detected on this Mac. The export file can still be imported manually.")
            }

        case .seratoCrate:
            warnings.append("Serato crate export is experimental and uses the reverse-engineered .crate format.")

            if detectedTargets.seratoDatabasePath == nil {
                warnings.append("Serato's library database was not detected. Direct crate write still proceeds when a matching _Serato_ root exists.")
            }

            if isSeratoRunning() {
                warnings.append("Serato appears to be running. Close the app before direct crate writes to avoid library refresh issues.")
            }

            let root: URL
            if let overrideRootPath = detectedTargets.seratoCratesRoot {
                root = URL(fileURLWithPath: overrideRootPath, isDirectory: true)
                guard fileManager.fileExists(atPath: root.path) else {
                    throw PlaylistExportError.seratoCratesRootUnavailable
                }
            } else {
                root = try resolveSeratoCratesRoot(for: preparedTracks.tracks)
            }
            seratoCratesRoot = root

            let existingCrateURL = root
                .appendingPathComponent("Subcrates", isDirectory: true)
                .appendingPathComponent(VendorPlaylistNaming.seratoCrateFileName(for: normalizedPlaylistName))
            if fileManager.fileExists(atPath: existingCrateURL.path) {
                warnings.append("An existing Serato crate with the same name will be backed up before replacement.")
            }
        }

        return PreparedVendorExport(
            playlistName: normalizedPlaylistName,
            safeFileBaseName: safeFileBaseName,
            tracks: preparedTracks.tracks,
            warnings: warnings,
            detectedTargets: detectedTargets,
            seratoCratesRoot: seratoCratesRoot
        )
    }

    private func preparedTracks(from tracks: [Track]) -> (tracks: [VendorExportTrack], warnings: [String]) {
        var prepared: [VendorExportTrack] = []
        var warnings: [String] = []
        var seenPaths = Set<String>()
        var duplicatePaths: [String] = []
        var missingPaths: [String] = []
        var invalidPathCount = 0

        for track in tracks {
            let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(track.filePath)
            guard !normalizedPath.isEmpty else {
                invalidPathCount += 1
                continue
            }

            if seenPaths.contains(normalizedPath) {
                duplicatePaths.append(normalizedPath)
                continue
            }
            seenPaths.insert(normalizedPath)

            guard fileManager.fileExists(atPath: normalizedPath) else {
                missingPaths.append(normalizedPath)
                continue
            }

            prepared.append(VendorExportTrack(track: track, normalizedPath: normalizedPath))
        }

        if invalidPathCount > 0 {
            warnings.append("Skipped \(invalidPathCount) track(s) with invalid file paths.")
        }
        if !duplicatePaths.isEmpty {
            warnings.append(summaryWarning(prefix: "Collapsed \(duplicatePaths.count) duplicate track path(s)", paths: duplicatePaths))
        }
        if !missingPaths.isEmpty {
            warnings.append(summaryWarning(prefix: "Skipped \(missingPaths.count) missing track file(s)", paths: missingPaths))
        }

        return (prepared, warnings)
    }

    private func summaryWarning(prefix: String, paths: [String]) -> String {
        let uniquePaths = Array(Set(paths)).sorted()
        let preview = uniquePaths.prefix(2).joined(separator: ", ")
        return preview.isEmpty ? prefix : "\(prefix): \(preview)"
    }

    private func preferredDefaultSeratoCratesRoot() -> URL? {
        let discoveredRoots = discoveredSeratoCratesRoots()
        let homeRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("_Serato_", isDirectory: true)

        if let homeMatch = discoveredRoots.first(where: { $0.path == homeRoot.path }) {
            return homeMatch
        }
        return discoveredRoots.count == 1 ? discoveredRoots[0] : discoveredRoots.first
    }

    private func resolveSeratoCratesRoot(for tracks: [VendorExportTrack]) throws -> URL {
        let candidateRoots = Array(Set(tracks.compactMap { seratoCratesRootCandidate(for: $0.normalizedPath)?.path })).sorted()
        guard !candidateRoots.isEmpty else {
            throw PlaylistExportError.seratoCratesRootUnavailable
        }

        if candidateRoots.count > 1 {
            throw PlaylistExportError.multipleSeratoRoots(candidateRoots)
        }

        let rootURL = URL(fileURLWithPath: candidateRoots[0], isDirectory: true)
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw PlaylistExportError.seratoCratesRootUnavailable
        }
        return rootURL
    }

    private func seratoCratesRootCandidate(for normalizedTrackPath: String) -> URL? {
        let homeDirectoryPath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        if normalizedTrackPath == homeDirectoryPath || normalizedTrackPath.hasPrefix(homeDirectoryPath + "/") {
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent("_Serato_", isDirectory: true)
        }

        let components = URL(fileURLWithPath: normalizedTrackPath).pathComponents
        guard components.count > 2, components[1] == "Volumes" else {
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent("_Serato_", isDirectory: true)
        }

        let volumeRoot = URL(fileURLWithPath: "/Volumes/\(components[2])", isDirectory: true)
        return volumeRoot.appendingPathComponent("_Serato_", isDirectory: true)
    }

    private func discoveredSeratoCratesRoots() -> [URL] {
        let homeRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("_Serato_", isDirectory: true)

        let volumeRoots = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []

        var candidates = [homeRoot]
        candidates.append(contentsOf: volumeRoots.map { $0.appendingPathComponent("_Serato_", isDirectory: true) })

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let normalizedPath = candidate.standardizedFileURL.path
            guard !seen.contains(normalizedPath) else { return nil }
            seen.insert(normalizedPath)
            guard fileManager.fileExists(atPath: normalizedPath) else { return nil }
            return URL(fileURLWithPath: normalizedPath, isDirectory: true)
        }
    }

    private func isSeratoRunning() -> Bool {
        runningApplicationTokensProvider().contains { token in
            token.localizedCaseInsensitiveContains("serato")
        }
    }
}

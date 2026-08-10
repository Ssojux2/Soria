import Foundation

struct RekordboxPlaylistWriter {
    func write(
        playlistName: String,
        tracks: [VendorExportTrack],
        to outputURL: URL
    ) throws -> URL {
        var lines = ["#EXTM3U"]
        for exportTrack in tracks {
            let duration = max(Int(exportTrack.track.duration.rounded()), 0)
            let artist = exportTrack.track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = exportTrack.track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = [artist, title]
                .filter { !$0.isEmpty }
                .joined(separator: " - ")
            let resolvedLabel = label.isEmpty ? exportTrack.track.fileName : label
            lines.append("#EXTINF:\(duration),\(resolvedLabel)")
            lines.append(exportTrack.normalizedPath)
        }

        let payload = lines.joined(separator: "\n") + "\n"
        try payload.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }
}

/// One playlist inside a rekordbox XML export. `name` may be `/`-separated to
/// nest the playlist under folder nodes.
struct RekordboxXMLPlaylist {
    let name: String
    let tracks: [VendorExportTrack]
}

struct RekordboxXMLWriter {
    func write(
        playlistName: String,
        tracks: [VendorExportTrack],
        to outputURL: URL
    ) throws -> URL {
        try write(playlists: [RekordboxXMLPlaylist(name: playlistName, tracks: tracks)], to: outputURL)
    }

    /// Writes any number of playlists into a single rekordbox library XML.
    ///
    /// rekordbox imports one XML at a time, so exporting a whole organized tree
    /// has to produce one document: a single COLLECTION deduplicated by location,
    /// and a PLAYLISTS tree whose folder nodes are shared between playlists that
    /// live under the same path.
    func write(playlists: [RekordboxXMLPlaylist], to outputURL: URL) throws -> URL {
        let document = XMLDocument()
        document.version = "1.0"
        document.characterEncoding = "UTF-8"

        let root = XMLElement(name: "DJ_PLAYLISTS")
        root.soria_addAttribute(name: "Version", value: "1.0.0")
        document.setRootElement(root)

        let product = XMLElement(name: "PRODUCT")
        product.soria_addAttribute(name: "Name", value: "Soria")
        product.soria_addAttribute(name: "Version", value: "1.0")
        product.soria_addAttribute(name: "Company", value: "BluePenguin")
        root.addChild(product)

        // A track in two playlists must appear once in COLLECTION; rekordbox keys
        // playlist membership off Location, so duplicates would fight each other.
        var uniqueTracks: [VendorExportTrack] = []
        var seenLocations = Set<String>()
        for playlist in playlists {
            for exportTrack in playlist.tracks where seenLocations.insert(exportTrack.rekordboxLocation).inserted {
                uniqueTracks.append(exportTrack)
            }
        }

        let collection = XMLElement(name: "COLLECTION")
        collection.soria_addAttribute(name: "Entries", value: "\(uniqueTracks.count)")
        root.addChild(collection)

        for (index, exportTrack) in uniqueTracks.enumerated() {
            collection.addChild(trackElement(for: exportTrack, trackID: index + 1))
        }

        let playlistsElement = XMLElement(name: "PLAYLISTS")
        root.addChild(playlistsElement)

        let rootNode = XMLElement(name: "NODE")
        rootNode.soria_addAttribute(name: "Type", value: "0")
        rootNode.soria_addAttribute(name: "Name", value: "ROOT")
        playlistsElement.addChild(rootNode)

        // Folder nodes are keyed by their full path so "House/Cluster 01" and
        // "House/Cluster 02" share one House node instead of creating two.
        var folderNodesByPath: [String: XMLElement] = [:]

        for playlist in playlists {
            let components = VendorPlaylistNaming.components(for: playlist.name)
            let leafName = components.last ?? playlist.name
            var currentFolder = rootNode
            var currentPath: [String] = []

            for folderName in components.dropLast() {
                currentPath.append(folderName)
                let key = currentPath.joined(separator: "/")
                if let existing = folderNodesByPath[key] {
                    currentFolder = existing
                    continue
                }
                let folderNode = XMLElement(name: "NODE")
                folderNode.soria_addAttribute(name: "Type", value: "0")
                folderNode.soria_addAttribute(name: "Name", value: folderName)
                currentFolder.addChild(folderNode)
                folderNodesByPath[key] = folderNode
                currentFolder = folderNode
            }

            let playlistNode = XMLElement(name: "NODE")
            playlistNode.soria_addAttribute(name: "Type", value: "1")
            playlistNode.soria_addAttribute(name: "Name", value: leafName)
            playlistNode.soria_addAttribute(name: "Entries", value: "\(playlist.tracks.count)")
            playlistNode.soria_addAttribute(name: "KeyType", value: "1")
            currentFolder.addChild(playlistNode)

            for exportTrack in playlist.tracks {
                let member = XMLElement(name: "TRACK")
                member.soria_addAttribute(name: "Key", value: exportTrack.rekordboxLocation)
                playlistNode.addChild(member)
            }
        }

        // Count is only meaningful once the tree is complete.
        applyFolderCounts(to: rootNode)

        let xmlData = document.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    /// Sets `Count` on every folder node to its number of child nodes.
    private func applyFolderCounts(to node: XMLElement) {
        let childNodes = (node.children ?? []).compactMap { $0 as? XMLElement }
            .filter { $0.name == "NODE" }
        node.soria_addAttribute(name: "Count", value: "\(childNodes.count)")
        for child in childNodes where child.attribute(forName: "Type")?.stringValue == "0" {
            applyFolderCounts(to: child)
        }
    }

    private func trackElement(for exportTrack: VendorExportTrack, trackID: Int) -> XMLElement {
        let trackElement = XMLElement(name: "TRACK")
        trackElement.soria_addAttribute(name: "TrackID", value: "\(trackID)")
        trackElement.soria_addAttribute(name: "Name", value: resolvedTrackTitle(for: exportTrack.track))
        trackElement.soria_addAttribute(name: "Artist", value: exportTrack.track.artist)
        trackElement.soria_addAttribute(name: "Album", value: exportTrack.track.album)
        trackElement.soria_addAttribute(name: "Genre", value: exportTrack.track.genre)
        trackElement.soria_addAttribute(name: "Location", value: exportTrack.rekordboxLocation)
        trackElement.soria_addAttribute(name: "AverageBpm", value: decimalString(exportTrack.track.bpm))
        trackElement.soria_addAttribute(name: "Tonality", value: exportTrack.track.musicalKey)
        if exportTrack.track.duration > 0 {
            trackElement.soria_addAttribute(
                name: "TotalTime",
                value: "\(max(Int(exportTrack.track.duration.rounded()), 0))"
            )
        }
        trackElement.soria_addAttribute(
            name: "DateAdded",
            value: Self.dateFormatter.string(from: exportTrack.track.modifiedTime)
        )
        return trackElement
    }

    private func resolvedTrackTitle(for track: Track) -> String {
        let trimmed = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? URL(fileURLWithPath: track.fileName).deletingPathExtension().lastPathComponent : trimmed
    }

    private func decimalString(_ value: Double?) -> String? {
        guard let value else { return nil }
        return Self.decimalFormatter.string(from: NSNumber(value: value))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        formatter.minimumIntegerDigits = 1
        formatter.decimalSeparator = "."
        return formatter
    }()
}

private extension XMLElement {
    func soria_addAttribute(name: String, value: String?) {
        guard let value, !value.isEmpty else { return }
        let attribute = XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
        addAttribute(attribute)
    }
}

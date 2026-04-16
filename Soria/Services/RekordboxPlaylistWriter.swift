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

struct RekordboxXMLWriter {
    func write(
        playlistName: String,
        tracks: [VendorExportTrack],
        to outputURL: URL
    ) throws -> URL {
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

        let collection = XMLElement(name: "COLLECTION")
        collection.soria_addAttribute(name: "Entries", value: "\(tracks.count)")
        root.addChild(collection)

        for (index, exportTrack) in tracks.enumerated() {
            let trackElement = XMLElement(name: "TRACK")
            trackElement.soria_addAttribute(name: "TrackID", value: "\(index + 1)")
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
            collection.addChild(trackElement)
        }

        let playlists = XMLElement(name: "PLAYLISTS")
        root.addChild(playlists)

        let rootNode = XMLElement(name: "NODE")
        rootNode.soria_addAttribute(name: "Type", value: "0")
        rootNode.soria_addAttribute(name: "Name", value: "ROOT")
        rootNode.soria_addAttribute(name: "Count", value: "1")
        playlists.addChild(rootNode)

        let components = VendorPlaylistNaming.components(for: playlistName)
        let finalPlaylistName = components.last ?? playlistName
        var currentFolder = rootNode
        let folderComponents = components.dropLast()
        for folderName in folderComponents {
            let folderNode = XMLElement(name: "NODE")
            folderNode.soria_addAttribute(name: "Type", value: "0")
            folderNode.soria_addAttribute(name: "Name", value: folderName)
            folderNode.soria_addAttribute(name: "Count", value: "1")
            currentFolder.addChild(folderNode)
            currentFolder = folderNode
        }

        let playlistNode = XMLElement(name: "NODE")
        playlistNode.soria_addAttribute(name: "Type", value: "1")
        playlistNode.soria_addAttribute(name: "Name", value: finalPlaylistName)
        playlistNode.soria_addAttribute(name: "Entries", value: "\(tracks.count)")
        playlistNode.soria_addAttribute(name: "KeyType", value: "1")
        currentFolder.addChild(playlistNode)

        for exportTrack in tracks {
            let member = XMLElement(name: "TRACK")
            member.soria_addAttribute(name: "Key", value: exportTrack.rekordboxLocation)
            playlistNode.addChild(member)
        }

        let xmlData = document.xmlData(options: [.nodePrettyPrint])
        try xmlData.write(to: outputURL, options: .atomic)
        return outputURL
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

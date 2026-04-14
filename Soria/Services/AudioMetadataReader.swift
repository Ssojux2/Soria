import AVFoundation
import Foundation

enum AudioMetadataReader {
    static func readMetadata(for url: URL) async -> (title: String, artist: String, album: String, genre: String, duration: TimeInterval, sampleRate: Double, bpm: Double?, musicalKey: String?) {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var genre = ""
        var bpm: Double?
        var musicalKey: String?

        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue else { continue }
            let value = item.stringValue ?? ""
            switch key {
            case "title": title = value
            case "artist": artist = value
            case "albumName": album = value
            case "type": genre = value
            default: break
            }
        }

        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                let key = item.commonKey?.rawValue.lowercased() ?? ""
                let value = item.stringValue ?? ""
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

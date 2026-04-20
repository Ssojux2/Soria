import Foundation

struct SeratoCrateWriteResult {
    let crateURL: URL
    let backupURL: URL?
}

struct SeratoCrateWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(
        playlistName _: String,
        tracks: [VendorExportTrack],
        cratesRoot: URL,
        crateURL: URL
    ) throws -> SeratoCrateWriteResult {
        let subcratesURL = crateURL.deletingLastPathComponent().standardizedFileURL
        try fileManager.createDirectory(at: subcratesURL, withIntermediateDirectories: true)

        let relativePaths = tracks.map { seratoRelativePath(for: $0.normalizedPath, cratesRoot: cratesRoot) }
        let payload = serializedCrateData(for: relativePaths)

        let backupURL = try backupExistingCrateIfNeeded(at: crateURL)
        try payload.write(to: crateURL, options: .atomic)

        return SeratoCrateWriteResult(crateURL: crateURL, backupURL: backupURL)
    }

    func serializedCrateData(for relativePaths: [String]) -> Data {
        var data = record(tag: "vrsn", payload: utf16BigEndianData("1.0/Serato ScratchLive Crate"))
        for relativePath in relativePaths {
            let trackPayload = record(tag: "ptrk", payload: utf16BigEndianData(relativePath))
            data.append(record(tag: "otrk", payload: trackPayload))
        }
        return data
    }

    func seratoRelativePath(for normalizedPath: String, cratesRoot: URL) -> String {
        let standardizedPath = TrackPathNormalizer.normalizedAbsolutePath(normalizedPath)
        let standardizedCratesRoot = cratesRoot.standardizedFileURL.path
        let homeRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("_Serato_", isDirectory: true)
            .standardizedFileURL.path

        if standardizedCratesRoot == homeRoot {
            return standardizedPath.trimmingPrefix("/")
        }

        let volumeRoot = cratesRoot.deletingLastPathComponent().standardizedFileURL.path
        if standardizedPath.hasPrefix(volumeRoot + "/") {
            return String(standardizedPath.dropFirst(volumeRoot.count + 1))
        }

        return standardizedPath.trimmingPrefix("/")
    }

    private func backupExistingCrateIfNeeded(at crateURL: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: crateURL.path) else { return nil }

        let timestamp = Self.backupTimestampFormatter.string(from: Date())
        let backupURL = crateURL.deletingLastPathComponent()
            .appendingPathComponent("\(crateURL.deletingPathExtension().lastPathComponent)-\(timestamp)")
            .appendingPathExtension("crate.bak")

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: crateURL, to: backupURL)
        return backupURL
    }

    private func record(tag: String, payload: Data) -> Data {
        var data = Data(tag.utf8)
        var bigEndianLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &bigEndianLength) { lengthBytes in
            data.append(contentsOf: lengthBytes)
        }
        data.append(payload)
        return data
    }

    private func utf16BigEndianData(_ string: String) -> Data {
        var data = Data()
        data.reserveCapacity(string.utf16.count * 2)
        for codeUnit in string.utf16 {
            var bigEndian = codeUnit.bigEndian
            withUnsafeBytes(of: &bigEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}

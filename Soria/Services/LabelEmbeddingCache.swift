import Foundation

/// Disk cache for genre-label and prompt embeddings.
///
/// Label vectors are stable for a given (prompt text, embedding profile) pair, but
/// building a plan needs all twelve genre labels at once. Without a cache every
/// press of Build Preview would spend twelve Gemini API calls re-deriving vectors
/// that never change.
///
/// Stored per profile at
/// `<worker cache>/label-embeddings/<sanitized profile id>.json`, so switching
/// embedding models never mixes vector spaces.
struct LabelEmbeddingCache {
    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = AppPaths.pythonCacheDirectory.appendingPathComponent(
            "label-embeddings",
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Returns cached vectors for `labels`, plus the labels still to be embedded.
    func load(labels: [String], profileID: String) -> (cached: [String: [Double]], missing: [String]) {
        let stored = readStore(profileID: profileID)
        var cached: [String: [Double]] = [:]
        var missing: [String] = []

        for label in labels {
            if let vector = stored[label], !vector.isEmpty {
                cached[label] = vector
            } else {
                missing.append(label)
            }
        }

        return (cached, missing)
    }

    /// Merges freshly embedded vectors into the profile's store.
    ///
    /// Cache writes are best-effort: a failure costs an API call next time, which
    /// is not worth failing a plan over.
    func store(_ embeddings: [String: [Double]], profileID: String) {
        guard !embeddings.isEmpty else { return }

        var merged = readStore(profileID: profileID)
        for (label, vector) in embeddings where !vector.isEmpty {
            merged[label] = vector
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(merged)
            try data.write(to: fileURL(profileID: profileID), options: .atomic)
        } catch {
            AppLogger.shared.error(
                "label_embedding_cache_write_failed profile=\(profileID) error=\(error.localizedDescription)"
            )
        }
    }

    func invalidate(profileID: String) {
        try? fileManager.removeItem(at: fileURL(profileID: profileID))
    }

    /// Mirrors the worker's profile-id sanitization so a slash in a model name
    /// cannot escape the cache directory.
    static func sanitizedProfileID(_ profileID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = profileID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(mapped)
        return sanitized.isEmpty ? "default" : sanitized
    }

    // MARK: - Private

    private func fileURL(profileID: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitizedProfileID(profileID)).json")
    }

    private func readStore(profileID: String) -> [String: [Double]] {
        guard let data = try? Data(contentsOf: fileURL(profileID: profileID)) else { return [:] }
        return (try? JSONDecoder().decode([String: [Double]].self, from: data)) ?? [:]
    }
}

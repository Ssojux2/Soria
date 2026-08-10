import Foundation

/// Durable write access to user-selected folders.
///
/// Release builds run inside the App Sandbox with only
/// `com.apple.security.files.user-selected.read-write`, which grants access to a
/// folder for the lifetime of the process that owns the open panel. Library roots
/// are persisted as plain path strings (see `LibraryRootsStore`), so after a
/// relaunch the app can read nothing and write nowhere. Anything that moves files
/// on disk — the organizer, the quarantine folder, Serato crate export — needs a
/// security-scoped bookmark minted at selection time and resolved on later launches.
///
/// Debug builds have `ENABLE_APP_SANDBOX = NO`, so every entry point here is a
/// pass-through: bookmark data is never minted and unit tests never touch the real
/// sandbox machinery.
enum SecurityScopedBookmarkStore {
    static let defaultsKey = "security.bookmarks.v1"

    enum BookmarkError: Error, LocalizedError {
        case bookmarkCreationFailed(path: String, underlying: Error)
        case bookmarkResolutionFailed(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .bookmarkCreationFailed(path, underlying):
                return "Could not remember access to \(path): \(underlying.localizedDescription)"
            case let .bookmarkResolutionFailed(path, underlying):
                return "Could not restore access to \(path): \(underlying.localizedDescription)"
            }
        }
    }

    /// True when the process runs inside the App Sandbox. Release only.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Minting

    /// Records a security-scoped bookmark for a folder the user just picked.
    ///
    /// Call this from every `NSOpenPanel` completion whose URL the app will need
    /// again after a relaunch. Outside the sandbox this is a no-op.
    static func store(url: URL, defaults: UserDefaults = .standard) throws {
        guard isSandboxed else { return }

        let path = TrackPathNormalizer.normalizedAbsolutePath(url)
        guard !path.isEmpty else { return }

        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var stored = storedBookmarks(defaults: defaults)
            stored[path] = data
            defaults.set(stored, forKey: defaultsKey)
        } catch {
            throw BookmarkError.bookmarkCreationFailed(path: path, underlying: error)
        }
    }

    static func forget(path: String, defaults: UserDefaults = .standard) {
        let normalized = TrackPathNormalizer.normalizedAbsolutePath(path)
        var stored = storedBookmarks(defaults: defaults)
        guard stored.removeValue(forKey: normalized) != nil else { return }
        defaults.set(stored, forKey: defaultsKey)
    }

    // MARK: - Querying

    static func storedBookmarkPaths(defaults: UserDefaults = .standard) -> [String] {
        storedBookmarks(defaults: defaults).keys.sorted()
    }

    /// Whether the app can still reach `path` after a relaunch.
    ///
    /// Unsandboxed builds always can. Sandboxed builds can only when the path
    /// itself, or one of its ancestors, was bookmarked at selection time.
    static func hasDurableAccess(toPath path: String, defaults: UserDefaults = .standard) -> Bool {
        guard isSandboxed else { return true }
        return coveringBookmarkPath(
            for: TrackPathNormalizer.normalizedAbsolutePath(path),
            storedPaths: storedBookmarkPaths(defaults: defaults)
        ) != nil
    }

    /// Resolves the bookmark covering `path` back into a URL, re-minting it when
    /// macOS reports the bookmark as stale. Returns nil when nothing covers it.
    static func resolveURL(forPath path: String, defaults: UserDefaults = .standard) -> URL? {
        guard isSandboxed else { return nil }

        let normalized = TrackPathNormalizer.normalizedAbsolutePath(path)
        let stored = storedBookmarks(defaults: defaults)
        guard let scopePath = coveringBookmarkPath(for: normalized, storedPaths: stored.keys.sorted()),
              let data = stored[scopePath] else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                refreshStaleBookmark(at: url, scopePath: scopePath, defaults: defaults)
            }
            return url
        } catch {
            AppLogger.shared.error(
                "security_scoped_bookmark resolve_failed path=\(scopePath) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Access

    /// Runs `body` while holding security-scoped access to everything covering `paths`.
    ///
    /// Access is released in reverse order even when `body` throws. Paths with no
    /// stored bookmark are skipped rather than failing the whole call — callers
    /// gate on `hasDurableAccess` first and surface a re-authorization prompt.
    static func withAccess<T>(
        toPaths paths: [String],
        defaults: UserDefaults = .standard,
        _ body: () throws -> T
    ) rethrows -> T {
        guard isSandboxed else { return try body() }

        let scopePaths = accessScopePaths(
            for: paths,
            storedPaths: storedBookmarkPaths(defaults: defaults)
        )

        var startedURLs: [URL] = []
        defer {
            for url in startedURLs.reversed() {
                url.stopAccessingSecurityScopedResource()
            }
        }

        for scopePath in scopePaths {
            guard let url = resolveURL(forPath: scopePath, defaults: defaults) else { continue }
            if url.startAccessingSecurityScopedResource() {
                startedURLs.append(url)
            }
        }

        return try body()
    }

    // MARK: - Pure helpers

    /// The deduplicated set of bookmarked folders needed to reach `targets`.
    ///
    /// Pure so it can be tested without minting real bookmarks: pass the stored
    /// keys in directly.
    static func accessScopePaths(for targets: [String], storedPaths: [String]) -> [String] {
        var scopePaths: [String] = []
        var seen = Set<String>()

        for target in targets {
            let normalized = TrackPathNormalizer.normalizedAbsolutePath(target)
            guard !normalized.isEmpty,
                  let scopePath = coveringBookmarkPath(for: normalized, storedPaths: storedPaths),
                  seen.insert(scopePath).inserted else {
                continue
            }
            scopePaths.append(scopePath)
        }

        return scopePaths
    }

    /// The deepest stored bookmark that contains `path`, or nil when none does.
    ///
    /// Matching is component-aware: `/Users/dj/Music` covers
    /// `/Users/dj/Music/House/a.mp3` but never `/Users/dj/MusicArchive`.
    static func coveringBookmarkPath(for path: String, storedPaths: [String]) -> String? {
        guard !path.isEmpty else { return nil }

        var best: String?
        for candidate in storedPaths where pathIsContained(path, in: candidate) {
            if best == nil || candidate.count > (best?.count ?? 0) {
                best = candidate
            }
        }
        return best
    }

    static func pathIsContained(_ path: String, in directory: String) -> Bool {
        guard !directory.isEmpty else { return false }
        if path == directory { return true }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: - Private

    private static func storedBookmarks(defaults: UserDefaults) -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private static func refreshStaleBookmark(at url: URL, scopePath: String, defaults: UserDefaults) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let refreshed = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var stored = storedBookmarks(defaults: defaults)
            stored[scopePath] = refreshed
            defaults.set(stored, forKey: defaultsKey)
        } catch {
            AppLogger.shared.error(
                "security_scoped_bookmark refresh_failed path=\(scopePath) error=\(error.localizedDescription)"
            )
        }
    }
}

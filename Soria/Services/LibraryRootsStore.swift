import Foundation

struct LibraryRootsStore {
    private static let key = "library.roots"
    private static let initialSetupCompletedKey = "library.initialSetupCompleted"
    private static let skipInitialSetupArgument = "UITEST_SKIP_INITIAL_SETUP"

    static func loadRoots() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func saveRoots(_ roots: [String]) {
        UserDefaults.standard.set(roots, forKey: key)
    }

    /// Mints a security-scoped bookmark for a folder the user just picked, so
    /// Release builds keep write access to it after a relaunch.
    ///
    /// Call this from every open-panel completion that yields a library root; the
    /// roots array itself stays owned by `AppViewModel`, which persists it through
    /// `saveRoots`. A bookmark can only be minted from the `URL` the panel handed
    /// back, which is why this takes a URL rather than a path.
    static func rememberAccess(to url: URL) {
        do {
            try SecurityScopedBookmarkStore.store(url: url)
        } catch {
            // 한국어: 북마크 발급 실패는 치명적이지 않습니다. 루트는 그대로 저장되고,
            // 재인증 배너가 사용자에게 폴더를 다시 고르도록 안내합니다.
            AppLogger.shared.error(
                "library_root_bookmark_failed path=\(TrackPathNormalizer.normalizedAbsolutePath(url)) "
                    + "error=\(error.localizedDescription)"
            )
        }
    }

    /// Roots that exist in settings but have no usable security-scoped bookmark.
    ///
    /// Non-empty only in sandboxed Release builds, and only for roots chosen
    /// before bookmarks were introduced. The UI asks the user to re-select these.
    static func rootsMissingDurableAccess(_ roots: [String] = loadRoots()) -> [String] {
        roots.filter { !SecurityScopedBookmarkStore.hasDurableAccess(toPath: $0) }
    }

    static func isInitialSetupCompleted() -> Bool {
        if ProcessInfo.processInfo.arguments.contains(skipInitialSetupArgument) {
            return true
        }
        return UserDefaults.standard.bool(forKey: initialSetupCompletedKey)
    }

    static func markInitialSetupCompleted() {
        UserDefaults.standard.set(true, forKey: initialSetupCompletedKey)
    }
}

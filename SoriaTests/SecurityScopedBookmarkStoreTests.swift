import Foundation
import Testing
@testable import Soria

/// Pure containment/scope-selection logic for security-scoped bookmarks.
///
/// These never mint a real bookmark: minting requires a user-selected URL and is
/// a no-op outside the sandbox anyway. What matters — and what silently breaks
/// file moves when it is wrong — is which stored bookmark covers a given target.
@Suite(.serialized)
struct SecurityScopedBookmarkStoreTests {
    @Test
    func containmentIsComponentAwareAndNotPlainPrefixMatching() {
        let root = "/Users/dj/Music"

        #expect(SecurityScopedBookmarkStore.pathIsContained(root, in: root))
        #expect(SecurityScopedBookmarkStore.pathIsContained("/Users/dj/Music/House/a.mp3", in: root))
        #expect(SecurityScopedBookmarkStore.pathIsContained("/Users/dj/Music/", in: root))

        // A plain hasPrefix check would wrongly accept these siblings.
        #expect(!SecurityScopedBookmarkStore.pathIsContained("/Users/dj/MusicArchive", in: root))
        #expect(!SecurityScopedBookmarkStore.pathIsContained("/Users/dj/MusicArchive/a.mp3", in: root))
        #expect(!SecurityScopedBookmarkStore.pathIsContained("/Users/dj", in: root))
        #expect(!SecurityScopedBookmarkStore.pathIsContained("/Users/dj/Music/a.mp3", in: ""))
    }

    @Test
    func coveringBookmarkPathPrefersTheDeepestMatchingRoot() {
        let stored = ["/Users/dj", "/Users/dj/Music", "/Volumes/Crate"]

        #expect(
            SecurityScopedBookmarkStore.coveringBookmarkPath(
                for: "/Users/dj/Music/House/a.mp3",
                storedPaths: stored
            ) == "/Users/dj/Music"
        )
        #expect(
            SecurityScopedBookmarkStore.coveringBookmarkPath(
                for: "/Users/dj/Documents/b.mp3",
                storedPaths: stored
            ) == "/Users/dj"
        )
        #expect(
            SecurityScopedBookmarkStore.coveringBookmarkPath(
                for: "/Volumes/Other/c.mp3",
                storedPaths: stored
            ) == nil
        )
        #expect(
            SecurityScopedBookmarkStore.coveringBookmarkPath(for: "", storedPaths: stored) == nil
        )
    }

    @Test
    func accessScopePathsDeduplicatesAndDropsUncoveredTargets() {
        let stored = ["/Users/dj/Music", "/Volumes/Crate"]
        let targets = [
            "/Users/dj/Music/House/a.mp3",
            "/Users/dj/Music/Techno/b.mp3",
            "/Volumes/Crate/c.mp3",
            "/Volumes/Unmounted/d.mp3",
            ""
        ]

        let scopes = SecurityScopedBookmarkStore.accessScopePaths(for: targets, storedPaths: stored)

        // Two tracks under the same root collapse to one scope; the uncovered
        // volume and the empty path drop out entirely.
        #expect(scopes == ["/Users/dj/Music", "/Volumes/Crate"])
    }

    @Test
    func accessScopePathsNormalizesTargetsBeforeMatching() {
        let stored = ["/Users/dj/Music"]

        let scopes = SecurityScopedBookmarkStore.accessScopePaths(
            for: ["file:///Users/dj/Music/House/a%20track.mp3", "/Users/dj/Music/./Techno/b.mp3"],
            storedPaths: stored
        )

        #expect(scopes == ["/Users/dj/Music"])
    }

    @Test
    func unsandboxedBuildsAlwaysReportDurableAccess() {
        // Debug builds run with ENABLE_APP_SANDBOX = NO, so every gate must open
        // and the organizer must not show a re-authorization banner.
        guard !SecurityScopedBookmarkStore.isSandboxed else { return }

        #expect(SecurityScopedBookmarkStore.hasDurableAccess(toPath: "/Users/dj/Music"))
        #expect(LibraryRootsStore.rootsMissingDurableAccess(["/Users/dj/Music", "/Volumes/Crate"]).isEmpty)
    }

    @Test
    func withAccessRunsTheBodyExactlyOnceAndPropagatesErrors() throws {
        struct Boom: Error {}

        var runCount = 0
        let value = SecurityScopedBookmarkStore.withAccess(toPaths: ["/Users/dj/Music"]) { () -> Int in
            runCount += 1
            return 42
        }
        #expect(value == 42)
        #expect(runCount == 1)

        #expect(throws: Boom.self) {
            try SecurityScopedBookmarkStore.withAccess(toPaths: ["/Users/dj/Music"]) {
                throw Boom()
            }
        }
    }
}

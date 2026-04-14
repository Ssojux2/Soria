import Foundation

struct LibraryRootsStore {
    private static let key = "library.roots"
    private static let initialSetupCompletedKey = "library.initialSetupCompleted"

    static func loadRoots() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func saveRoots(_ roots: [String]) {
        UserDefaults.standard.set(roots, forKey: key)
    }

    static func isInitialSetupCompleted() -> Bool {
        UserDefaults.standard.bool(forKey: initialSetupCompletedKey)
    }

    static func markInitialSetupCompleted() {
        UserDefaults.standard.set(true, forKey: initialSetupCompletedKey)
    }
}

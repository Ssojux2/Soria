import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case scanJobs = "Scan Jobs"
    case analysis = "Analysis"
    case recommendations = "Recommendations"
    case exports = "Exports"
    case settings = "Settings"

    var id: String { rawValue }
}

struct ScanJobProgress {
    var scannedFiles: Int = 0
    var totalFiles: Int = 0
    var indexedFiles: Int = 0
    var skippedFiles: Int = 0
    var duplicateFiles: Int = 0
    var isRunning: Bool = false
    var currentFile: String = ""
}

struct ExportJobResult {
    var outputPaths: [String]
    var message: String
}

enum EmbeddingProvider: String, CaseIterable, Identifiable {
    case googleEmbedding2 = "google_embedding_2"
    case clapEmbedding = "clap_embedding"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .googleEmbedding2:
            return "Google Embedding 2"
        case .clapEmbedding:
            return "CLAP Embedding"
        }
    }
}

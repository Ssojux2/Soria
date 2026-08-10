import Foundation

/// Outcome of moving tracks into the Soria quarantine folder.
///
/// Partial success is normal — a locked file or a missing source should not abort
/// the rest of the batch — so failures travel alongside successes rather than as a
/// thrown error.
struct QuarantineMoveResult: Equatable {
    var batchID: UUID
    var movedTrackIDs: [UUID] = []
    var skipped: [SkippedTrack] = []
    var failed: [FailedTrack] = []
    var warnings: [String] = []

    struct SkippedTrack: Equatable {
        let trackID: UUID
        let path: String
        let reason: String
    }

    struct FailedTrack: Equatable {
        let trackID: UUID
        let path: String
        let message: String
    }

    var movedCount: Int { movedTrackIDs.count }
    var hasFailures: Bool { !failed.isEmpty }

    var summaryMessage: String {
        var segments = ["Moved \(movedCount) track\(movedCount == 1 ? "" : "s") to Soria Trash."]
        if !skipped.isEmpty {
            segments.append("Skipped \(skipped.count).")
        }
        if !failed.isEmpty {
            segments.append("\(failed.count) failed.")
        }
        return segments.joined(separator: " ")
    }
}

/// Outcome of restoring quarantined tracks to their original locations, or of
/// purging them to the system Trash.
struct QuarantineRestoreResult: Equatable {
    var restoredTrackIDs: [UUID] = []
    var failed: [QuarantineMoveResult.FailedTrack] = []
    var warnings: [String] = []

    var restoredCount: Int { restoredTrackIDs.count }
    var hasFailures: Bool { !failed.isEmpty }

    var summaryMessage: String {
        var segments = ["Restored \(restoredCount) track\(restoredCount == 1 ? "" : "s")."]
        if !failed.isEmpty {
            segments.append("\(failed.count) failed.")
        }
        return segments.joined(separator: " ")
    }

    var purgeSummaryMessage: String {
        var segments = ["Moved \(restoredCount) track\(restoredCount == 1 ? "" : "s") to the system Trash."]
        if !failed.isEmpty {
            segments.append("\(failed.count) failed.")
        }
        return segments.joined(separator: " ")
    }
}

/// One row in the quarantine review table: the persisted record joined with
/// whatever the library still knows about the track.
struct QuarantineRow: Identifiable, Hashable {
    var id: UUID { record.trackID }

    let record: TrackQuarantineRecord
    let title: String
    let artist: String
    /// False when the quarantined file is no longer where Soria left it — the user
    /// moved or deleted it in Finder, so restore cannot succeed.
    let fileExists: Bool

    var originalFolderName: String {
        URL(fileURLWithPath: record.originalPath).deletingLastPathComponent().lastPathComponent
    }

    var statusText: String {
        fileExists ? "In Soria Trash" : "Missing from Soria Trash"
    }
}

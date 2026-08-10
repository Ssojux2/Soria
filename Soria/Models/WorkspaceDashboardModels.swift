import Foundation

/// Everything the Home dashboard needs, collected into plain values.
///
/// Same shape as `PreparationOverviewContext`: the view model gathers the inputs,
/// a pure function turns them into display state, and the tests exercise that
/// function without a database, a worker, or a window.
///
/// Note what is *not* here — no "can this run" logic is derived from these fields.
/// The `can…` flags arrive already computed by the properties the existing panes
/// use (`canExportPlaylist`, `LibraryOrganizerModel.canExportCollections`, and so
/// on). Home must never grow a second opinion about whether a button works, or it
/// will drift away from the pane that owns the action.
struct WorkspaceDashboardContext: Equatable {
    var totalTrackCount: Int = 0
    var readyTrackCount: Int = 0
    var needsPreparationCount: Int = 0

    var libraryRootCount: Int = 0
    var isValidated: Bool = false
    var validationSummary: String = ""
    var embeddingProfileName: String = ""
    var hasResolvedWorkerPaths: Bool = true
    var enabledVendorSourceNames: [String] = []

    var soriaFolderCount: Int = 0
    var quarantinedTrackCount: Int = 0
    var latestOrganizationDate: Date?
    var canExportFolders: Bool = false

    var readyReferenceCount: Int = 0
    var generatedRecommendationCount: Int = 0
    var canGenerateRecommendations: Bool = false

    var playlistQueueCount: Int = 0
    var exportTargetName: String = ""
    var canExportQueue: Bool = false
}

/// A setup problem worth showing before the user tries to run anything.
///
/// Ordered by how early it blocks the pipeline, so the first entry is the one to
/// fix first.
struct WorkspaceSetupIssue: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case musicFolders
        case validation
        case workerPaths
        case emptyLibrary
    }

    let kind: Kind
    let title: String
    let detail: String

    var id: String { kind.rawValue }
}

struct WorkspaceOrganizeCard: Equatable {
    var summary: String
    var detail: String
    var latestOrganizationDate: Date?
    /// `nil` when the Soria Trash is empty, so the card hides the row entirely
    /// rather than showing a reassuring "0".
    var trashSummary: String?
    var canExportFolders: Bool
    var canRestoreTrash: Bool
}

struct WorkspaceMixCard: Equatable {
    var summary: String
    var detail: String
    var generatedSummary: String?
    var canGenerate: Bool
}

struct WorkspaceExportCard: Equatable {
    var summary: String
    var detail: String
    var canExport: Bool
}

/// What the Home screen draws.
struct WorkspaceDashboardState: Equatable {
    var headline: String
    var readinessSummary: String
    var profileSummary: String
    var setupIssues: [WorkspaceSetupIssue]
    var organize: WorkspaceOrganizeCard
    var mix: WorkspaceMixCard
    var export: WorkspaceExportCard

    /// Drives whether the Setup card is shown at all. A healthy setup should not
    /// spend a card telling the user nothing is wrong.
    var isSetupHealthy: Bool { setupIssues.isEmpty }
}

extension WorkspaceDashboardState {
    static func make(from context: WorkspaceDashboardContext) -> WorkspaceDashboardState {
        WorkspaceDashboardState(
            headline: makeHeadline(from: context),
            readinessSummary: makeReadinessSummary(from: context),
            profileSummary: makeProfileSummary(from: context),
            setupIssues: makeSetupIssues(from: context),
            organize: makeOrganizeCard(from: context),
            mix: makeMixCard(from: context),
            export: makeExportCard(from: context)
        )
    }

    // MARK: - Header

    private static func makeHeadline(from context: WorkspaceDashboardContext) -> String {
        guard context.totalTrackCount > 0 else {
            return "No tracks indexed yet"
        }
        return "\(pluralized(context.totalTrackCount, "track")) indexed"
    }

    private static func makeReadinessSummary(from context: WorkspaceDashboardContext) -> String {
        guard context.totalTrackCount > 0 else {
            return "Add a music folder and scan it to build the library."
        }

        var parts = ["\(formatted(context.readyTrackCount)) ready"]
        if context.needsPreparationCount > 0 {
            parts.append("\(formatted(context.needsPreparationCount)) need prep")
        }
        if context.quarantinedTrackCount > 0 {
            parts.append("\(formatted(context.quarantinedTrackCount)) in Soria Trash")
        }
        return parts.joined(separator: " · ")
    }

    private static func makeProfileSummary(from context: WorkspaceDashboardContext) -> String {
        let profile = context.embeddingProfileName.isEmpty ? "No model selected" : context.embeddingProfileName
        let validation = context.isValidated ? "Validated" : "Not validated"
        var parts = [profile, validation]
        if !context.enabledVendorSourceNames.isEmpty {
            parts.append(context.enabledVendorSourceNames.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Setup

    private static func makeSetupIssues(from context: WorkspaceDashboardContext) -> [WorkspaceSetupIssue] {
        var issues: [WorkspaceSetupIssue] = []

        if context.libraryRootCount == 0 {
            issues.append(
                WorkspaceSetupIssue(
                    kind: .musicFolders,
                    title: "No music folder connected",
                    detail: "Choose the folder Soria should treat as your library, then scan it."
                )
            )
        }

        if !context.isValidated {
            issues.append(
                WorkspaceSetupIssue(
                    kind: .validation,
                    title: "Analysis model not validated",
                    detail: context.validationSummary.isEmpty
                        ? "Add your Google AI API key and validate it before preparing tracks."
                        : context.validationSummary
                )
            )
        }

        if !context.hasResolvedWorkerPaths {
            issues.append(
                WorkspaceSetupIssue(
                    kind: .workerPaths,
                    title: "Analysis worker not found",
                    detail: "Point Soria at a Python executable and the worker script in Settings."
                )
            )
        }

        // Only worth saying once the folders are actually connected — otherwise it
        // just repeats the first issue.
        if context.libraryRootCount > 0 && context.totalTrackCount == 0 {
            issues.append(
                WorkspaceSetupIssue(
                    kind: .emptyLibrary,
                    title: "Library is empty",
                    detail: "Scan your music folders to index the tracks Soria can work with."
                )
            )
        }

        return issues
    }

    // MARK: - Cards

    private static func makeOrganizeCard(from context: WorkspaceDashboardContext) -> WorkspaceOrganizeCard {
        let summary = context.soriaFolderCount > 0
            ? pluralized(context.soriaFolderCount, "Soria folder")
            : "No Soria folders yet"

        let detail: String = if context.soriaFolderCount > 0 {
            "Export them straight to Serato or rekordbox, or open the plan to move files."
        } else if context.readyTrackCount > 0 {
            "Build a folder plan from your prepared tracks, or draw a region on the map."
        } else {
            "Prepare some tracks first — organizing works from the analysis results."
        }

        return WorkspaceOrganizeCard(
            summary: summary,
            detail: detail,
            latestOrganizationDate: context.latestOrganizationDate,
            trashSummary: context.quarantinedTrackCount > 0
                ? "\(pluralized(context.quarantinedTrackCount, "track")) in Soria Trash"
                : nil,
            canExportFolders: context.canExportFolders,
            canRestoreTrash: context.quarantinedTrackCount > 0
        )
    }

    private static func makeMixCard(from context: WorkspaceDashboardContext) -> WorkspaceMixCard {
        let summary = context.readyReferenceCount > 0
            ? "\(pluralized(context.readyReferenceCount, "ready reference"))"
            : "No reference tracks selected"

        let detail = context.readyReferenceCount > 0
            ? "Describe the transition you want, or generate straight from the selection."
            : "Select prepared tracks in the library, or just describe what you want."

        return WorkspaceMixCard(
            summary: summary,
            detail: detail,
            generatedSummary: context.generatedRecommendationCount > 0
                ? "\(pluralized(context.generatedRecommendationCount, "candidate")) generated"
                : nil,
            canGenerate: context.canGenerateRecommendations
        )
    }

    private static func makeExportCard(from context: WorkspaceDashboardContext) -> WorkspaceExportCard {
        let summary = context.playlistQueueCount > 0
            ? "\(pluralized(context.playlistQueueCount, "track")) queued"
            : "Queue is empty"

        let detail: String = if context.playlistQueueCount > 0 {
            context.exportTargetName.isEmpty
                ? "Pick a target and export."
                : "Exports to \(context.exportTargetName)."
        } else {
            "Build a playlist path in the Mix Assistant to fill the queue."
        }

        return WorkspaceExportCard(
            summary: summary,
            detail: detail,
            canExport: context.canExportQueue
        )
    }

    // MARK: - Formatting

    /// Pinned to `en_US` rather than the user's locale.
    ///
    /// Every label in this app is English, so the grouping should match the words
    /// beside it, and a fixed locale keeps these strings comparable in tests on any
    /// machine. Not `en_US_POSIX`: that locale drops grouping separators entirely,
    /// which is what you want for machine-readable output and exactly wrong for a
    /// five-thousand-track count a person has to read.
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func formatted(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(formatted(count)) \(noun)\(count == 1 ? "" : "s")"
    }
}

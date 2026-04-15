import Foundation
import Testing
@testable import Soria

struct AnalysisProgressTests {
    @Test
    func workerStderrRouterSeparatesProgressEventsFromPlainText() {
        var events: [WorkerProgressEvent] = []
        let router = WorkerStderrRouter { event in
            events.append(event)
        }

        let payload = """
        \(PythonWorkerClient.workerProgressPrefix){"stage":"extracting_features","message":"Extracting rhythmic and spectral features","fraction":0.3,"trackPath":"/tmp/example.mp3","timestamp":"2026-04-15T06:30:00Z"}
        plain stderr line
        """

        let splitIndex = payload.index(payload.startIndex, offsetBy: 45)
        router.append(Data(payload[..<splitIndex].utf8))
        router.append(Data(payload[splitIndex...].utf8))
        router.finish()

        #expect(events.count == 1)
        #expect(events.first?.stage == .extractingFeatures)
        #expect(events.first?.message == "Extracting rhythmic and spectral features")
        #expect(events.first?.trackPath == "/tmp/example.mp3")
        #expect(router.plainText == "plain stderr line")
    }

    @Test
    func analysisActivityTracksProgressAndCompletion() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var activity = AnalysisActivity.started(
            trackTitle: "Example Track",
            trackPath: "/tmp/example.mp3",
            queueIndex: 2,
            totalCount: 4,
            timeoutSec: 120,
            startedAt: startedAt
        )

        activity.recordProgress(
            WorkerProgressEvent(
                stage: .extractingFeatures,
                message: "Extracting rhythmic and spectral features",
                fraction: 0.30,
                trackPath: "/tmp/example.mp3",
                timestamp: startedAt.addingTimeInterval(3)
            ),
            trackTitle: "Example Track",
            fallbackTrackPath: "/tmp/example.mp3",
            queueIndex: 2,
            totalCount: 4
        )

        #expect(activity.stage == .extractingFeatures)
        #expect(activity.currentMessage == "Extracting rhythmic and spectral features")
        #expect(abs((activity.overallProgress ?? 0) - 0.325) < 0.0001)

        activity.markFinished(
            state: .failed,
            errorMessage: "Worker timed out after 120 seconds.",
            message: "Failed Example Track",
            at: startedAt.addingTimeInterval(120)
        )

        #expect(activity.finalState == .failed)
        #expect(activity.lastErrorMessage == "Worker timed out after 120 seconds.")
        #expect(activity.displayedEvents.first?.message == "Failed Example Track")
    }

    @Test
    func timedOutWorkerErrorIncludesDetail() {
        let error = WorkerError.timedOut(120, detail: "Last stderr line")
        #expect(error.localizedDescription.contains("120"))
        #expect(error.localizedDescription.contains("Last stderr line"))
    }
}

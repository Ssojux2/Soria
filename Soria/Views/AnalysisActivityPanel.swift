import AppKit
import SwiftUI

struct AnalysisActivityPanel: View {
    let activity: AnalysisActivity
    @Binding var isExpanded: Bool

    var body: some View {
        GroupBox("Analysis Activity") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    progressSection

                    TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                        HStack(spacing: 12) {
                            Text("Elapsed: \(elapsedText(now: context.date))")
                            Text("Timeout: \(Int(activity.timeoutSec))s")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if !activity.displayedEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Worker Events")
                                .font(.headline)
                            ForEach(activity.displayedEvents) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(timeText(for: event.timestamp))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.stage.displayName)
                                            .font(.footnote.weight(.semibold))
                                        Text(event.message)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if let errorMessage = activity.lastErrorMessage, !errorMessage.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Last Error")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("App log: \(appLogPath)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Worker log: \(workerLogPath)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Reveal Logs") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: appLogPath),
                                    URL(fileURLWithPath: workerLogPath)
                                ])
                            }
                            .buttonStyle(.link)
                        }
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                header
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.currentTrackTitle)
                    .font(.headline)
                Text("\(activity.queueIndex) / \(activity.totalCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(activity.headlineText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let overallProgress = activity.overallProgress {
                ProgressView(value: overallProgress, total: 1)
            } else {
                ProgressView()
            }

            Text(activity.currentMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch activity.finalState {
        case .some(.succeeded):
            return .green
        case .some(.failed):
            return .red
        case .some(.canceled):
            return .orange
        default:
            return .blue
        }
    }

    private var appLogPath: String {
        AppPaths.logsDirectory.appendingPathComponent("app.log").path
    }

    private var workerLogPath: String {
        AppPaths.pythonCacheDirectory.appendingPathComponent("worker.log").path
    }

    private func elapsedText(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(activity.startedAt)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func timeText(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }
}

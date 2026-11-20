import AetherUnzipKit
import SwiftUI

private extension TaskRecord.State {
    var title: String {
        switch self {
        case .running: String(localized: "Extracting")
        case .success: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .skipped: String(localized: "Skipped")
        case .cancelled: String(localized: "Cancelled")
        case .interrupted: String(localized: "Interrupted")
        }
    }

    var symbol: String {
        switch self {
        case .running: "arrow.down.to.line"
        case .success: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .skipped: "arrow.turn.down.right"
        case .cancelled: "stop"
        case .interrupted: "pause.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .success: .green
        case .failed: .red
        case .cancelled, .skipped, .interrupted: .orange
        }
    }
}

struct TaskBanner: View {
    @Bindable var model: AppModel
    var openOutput: (() -> Void)? = nil
    var openResults: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let current = model.current {
                inProgress(current)
                    .transition(reduceMotion ? .identity : .opacity)
            } else if let notice = model.notice {
                result(notice)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : WorkspaceMotion.layout, value: model.current != nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 5)
    }

    private func inProgress(_ current: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                WorkspaceGlyph(symbol: "arrow.down.to.line", tint: .accentColor)
                Text(model.cancelling ? "Cancelling…" : "Extracting \(current.archive)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel", action: model.cancelExtraction)
                    .disabled(model.cancelling)
            }
            TaskProgress(model: model)
        }
    }

    private func result(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                let partial = model.noticeIsPartial || model.lastOutput == nil
                WorkspaceGlyph(symbol: partial ? "exclamationmark.circle" : "checkmark",
                               tint: partial ? .orange : .green)
                Text(notice).font(.subheadline)
                Spacer(minLength: 0)
                if !model.noticeIsBatch { outputButton }
                Button { model.notice = nil } label: {
                    Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if model.noticeIsBatch, let openResults {
                HStack(spacing: 16) {
                    Button("View Results", action: openResults)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("view-batch-results")
                    outputButton
                }
            }
        }
    }

    @ViewBuilder private var outputButton: some View {
        if let openOutput, model.lastOutput != nil {
            Button("View Folder", action: openOutput)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("view-extraction-folder")
        }
    }
}

private struct TaskProgress: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let batch = model.batchPosition {
                Text("Archive \(batch.index) of \(batch.total)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("batch-extraction-progress")
            }
            if let progress = model.progress {
                if progress.totalEntries > 0 {
                    ProgressView(value: progress.fractionCompleted)
                        .accessibilityLabel("Extraction progress")
                    Text("\(progress.entriesDone) of \(progress.totalEntries) entries processed")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(spacing: 6) {
                    Text(progress.currentEntry.path).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(formattedBytes(progress.bytesWritten)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView("Preparing files…")
                    .progressViewStyle(.linear)
            }
        }
    }
}

struct ActivityView: View {
    let model: AppModel
    let reopen: (RecentArchive) -> Void
    let openBatchResults: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details: TaskRecord?
    @State private var showAllRecents = false
    @State private var confirmingClearActivity = false
    private let recentPreviewCount = 4

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: String(localized: "Activity"))
                .modifier(WorkspaceHeaderLayout())
            if model.current == nil && model.recents.isEmpty && model.history.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Opened archives and extractions will appear here."))
            } else {
                List {
                    if let current = model.current {
                        Section("In Progress") {
                            VStack(alignment: .leading, spacing: 8) {
                                row(current)
                                TaskProgress(model: model)
                                Button(model.cancelling ? "Cancelling…" : "Cancel Extraction", role: .cancel,
                                       action: model.cancelExtraction)
                                    .disabled(model.cancelling)
                                    .accessibilityIdentifier("cancel-extraction")
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    if !model.recents.isEmpty {
                        Section("Recently Opened") {
                            let count = showAllRecents ? model.recents.count : recentPreviewCount
                            ForEach(model.recents.prefix(count)) { item in recentRow(item) }
                            if model.recents.count > recentPreviewCount {
                                Button {
                                    withAnimation(reduceMotion ? nil : WorkspaceMotion.layout) {
                                        showAllRecents.toggle()
                                    }
                                } label: {
                                    Label {
                                        Text(showAllRecents ? "Show Fewer Recent Archives" : "Show All Recent Archives")
                                            .contentTransition(reduceMotion ? .identity : .opacity)
                                    } icon: {
                                        Image(systemName: "chevron.down")
                                            .rotationEffect(.degrees(showAllRecents ? 180 : 0))
                                    }
                                    .font(.subheadline)
                                }
                                .accessibilityIdentifier("activity-toggle-recents")
                            }
                        }
                    }
                    if !model.history.isEmpty {
                        Section("Extraction History") {
                            if model.batchResult != nil {
                                Button("Latest Batch Results", systemImage: "archivebox", action: openBatchResults)
                            }
                            ForEach(model.history) { task in
                                Group {
                                    if task.details != nil {
                                        Button { details = task } label: { row(task) }
                                            .buttonStyle(.plain)
                                    } else {
                                        row(task)
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            }
                        }
                    }
                    if !model.recents.isEmpty || !model.history.isEmpty {
                        Section {
                            Button("Clear Activity…", systemImage: "trash", role: .destructive) {
                                confirmingClearActivity = true
                            }
                            .disabled(model.current != nil)
                            .accessibilityIdentifier("activity-clear")
                        }
                    }
                }
                .modifier(WorkspaceListSurface())
            }
        }
        .modifier(WorkspaceCanvas())
        .confirmationDialog("Clear Activity?", isPresented: $confirmingClearActivity, titleVisibility: .visible) {
            Button("Clear Activity", role: .destructive, action: model.clearActivity)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears recently opened archives and extraction history from the activity list.")
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(item: $details) { task in
            VStack(alignment: .leading, spacing: 12) {
                WorkspaceHeading(title: task.archive, symbol: task.state.symbol, tint: task.state.tint,
                                 detail: task.state.title)
                Text(task.details ?? "").textSelection(.enabled)
                Button("Done") { details = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            #if os(macOS)
            .frame(minWidth: 360)
            #endif
        }
    }

    private func row(_ task: TaskRecord) -> some View {
        HStack(spacing: 10) {
            WorkspaceGlyph(symbol: task.state.symbol, tint: task.state.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.archive)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("activity-extraction-\(task.archive)")
                Text(task.destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(task.state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(task.state.tint.opacity(0.14), in: Capsule())
                Text(task.started, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }

    private func recentRow(_ item: RecentArchive) -> some View {
        Button { reopen(item) } label: {
            HStack(spacing: 10) {
                WorkspaceGlyph(symbol: "doc.zipper", tint: .teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                        .lineLimit(2).truncationMode(.middle)
                    Text("\(item.format) · \(formattedBytes(item.size))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityIdentifier("activity-recent-\(item.name)")
        .swipeActions {
            Button("Remove from Recents", systemImage: "trash", role: .destructive) { model.remove(item) }
        }
        .contextMenu {
            Button("Remove from Recents", role: .destructive) { model.remove(item) }
        }
    }
}

struct BatchResultsView: View {
    let model: AppModel
    let openOutput: (BrowserFolder) -> Void
    let retry: (UUID, PasswordChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passwordEntry: BatchResult.Entry?

    var body: some View {
        NavigationStack {
            List {
                if model.current != nil {
                    Section("In Progress") {
                        TaskProgress(model: model)
                        Button(model.cancelling ? "Cancelling…" : "Cancel Extraction", role: .cancel,
                               action: model.cancelExtraction).disabled(model.cancelling)
                    }
                }
                let entries = model.batchResult?.entries ?? []
                ForEach([TaskRecord.State.failed, .interrupted, .skipped, .cancelled, .success], id: \.self) { state in
                    let matching = entries.filter { $0.record.state == state }
                    if !matching.isEmpty {
                        Section(state.title) {
                            ForEach(matching) { entry in resultRow(entry) }
                        }
                    }
                }
            }
            .modifier(WorkspaceListSurface())
            .modifier(WorkspaceCanvas())
            .navigationTitle("Batch Results")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
        .sheet(item: $passwordEntry) { entry in
            PasswordPrompt(archiveName: entry.record.archive, actionTitle: "Retry Extraction",
                           library: model.passwords) { choice in
                passwordEntry = nil
                retry(entry.id, choice)
            }
        }
    }

    private func resultRow(_ entry: BatchResult.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.record.archive, systemImage: entry.record.state.symbol)
                .font(.subheadline.weight(.semibold))
            if let details = entry.record.details {
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            if let output = entry.output {
                Text(output.breadcrumb).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Button("View Folder", systemImage: "folder") { openOutput(output) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("batch-output-\(entry.record.archive)")
            }
            if entry.canRetry {
                Button(entry.needsPassword ? "Enter Password" : "Retry Extraction",
                       systemImage: entry.needsPassword ? "key" : "arrow.clockwise") {
                    if entry.needsPassword { passwordEntry = entry }
                    else { retry(entry.id, .automatic) }
                }
                .buttonStyle(.borderless)
                .disabled(model.current != nil)
                .accessibilityIdentifier("batch-retry-\(entry.record.archive)")
            }
        }
        .padding(.vertical, 4)
    }
}

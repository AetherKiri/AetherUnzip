import SwiftUI

private extension TaskRecord.State {
    var title: String {
        switch self {
        case .running: String(localized: "Extracting")
        case .success: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    var symbol: String {
        switch self {
        case .running: "arrow.down.to.line"
        case .success: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop"
        }
    }

    var tint: Color {
        switch self {
        case .running: .accentColor
        case .success: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

struct TaskBanner: View {
    @Bindable var model: AppModel
    var openOutput: (() -> Void)? = nil
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
        HStack(spacing: 8) {
            let partial = model.noticeIsPartial || model.lastOutput == nil
            WorkspaceGlyph(symbol: partial ? "exclamationmark.circle" : "checkmark",
                           tint: partial ? .orange : .green)
            Text(notice).font(.subheadline)
            Spacer(minLength: 0)
            if let openOutput, model.lastOutput != nil {
                Button("View Folder", action: openOutput)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("view-extraction-folder")
            }
            Button { model.notice = nil } label: {
                Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("Preparing extraction")
            }
        }
    }
}

struct ActivityView: View {
    let model: AppModel
    let reopen: (RecentArchive) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details: TaskRecord?
    @State private var showAllRecents = false
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
                }
                .modifier(WorkspaceListSurface())
            }
        }
        .modifier(WorkspaceCanvas())
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

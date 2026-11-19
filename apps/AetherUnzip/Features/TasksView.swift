import SwiftUI

private extension TaskRecord.State {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current = model.current {
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
            } else if let notice = model.notice {
                HStack(spacing: 8) {
                    WorkspaceGlyph(symbol: model.lastOutput == nil ? "stop" : "checkmark",
                                   tint: model.lastOutput == nil ? .orange : .green)
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
}

private struct TaskProgress: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

struct TasksView: View {
    var model: AppModel
    @State private var details: TaskRecord?

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: "Tasks",
                             detail: model.history.isEmpty ? nil : "\(model.history.count) recent")
                .modifier(WorkspaceHeaderLayout())
            if model.current == nil && model.history.isEmpty {
                ContentUnavailableView("No Extraction Tasks", systemImage: "tray")
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
                    if !model.history.isEmpty {
                        Section("History") {
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
        .accessibilityIdentifier("tasks-page")
        .sheet(item: $details) { task in
            VStack(alignment: .leading, spacing: 12) {
                WorkspaceHeading(title: task.archive, symbol: task.state.symbol, tint: task.state.tint,
                                 detail: task.state.rawValue)
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
                Text(task.archive).font(.body.weight(.medium)).lineLimit(2).truncationMode(.middle)
                Text(task.destination).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(task.state.rawValue)
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
}

import SwiftUI

struct TaskBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let current = model.current {
                HStack {
                    Text(model.cancelling ? "Cancelling…" : "Extracting \(current.archive)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel", action: model.cancelExtraction)
                        .disabled(model.cancelling)
                }
                if let progress = model.progress {
                    ProgressView(value: progress.fractionCompleted)
                    HStack {
                        Text(progress.currentEntry.path).lineLimit(1)
                        Spacer()
                        Text(formattedBytes(progress.bytesWritten))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            } else if let notice = model.notice {
                HStack {
                    Text(notice).font(.callout)
                    Spacer()
                    Button { model.notice = nil } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }
}

struct TasksView: View {
    var model: AppModel

    var body: some View {
        Group {
            if model.current == nil && model.history.isEmpty {
                ContentUnavailableView("No Extraction Tasks", systemImage: "list.bullet.rectangle")
            } else {
                List {
                    if let current = model.current {
                        Section("Current") { row(current) }
                    }
                    if !model.history.isEmpty {
                        Section("Recent") {
                            ForEach(model.history) { row($0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tasks")
    }

    private func row(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.archive).font(.headline)
            Text("\(task.state.rawValue) · \(task.destination)")
            Text(task.started.formatted(date: .abbreviated, time: .shortened))
            if let details = task.details { Text(details).foregroundStyle(.red) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

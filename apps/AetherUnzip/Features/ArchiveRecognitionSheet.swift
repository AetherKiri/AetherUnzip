import AetherUnzipKit
import SwiftUI

struct ArchiveRecognitionRequest: Identifiable {
    let id = UUID()
    let name: String
    let folder: BrowserFolder

    var url: URL { folder.item(name) }
}

struct ArchiveRecognitionSheet: View {
    let request: ArchiveRecognitionRequest
    let limits: ExtractionOptions.Limits
    let open: (URL, Bool) -> Void

    private enum Result {
        case reading, verified(ArchiveManifest), locked, failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var result = Result.reading
    @State private var attempt = 0
    @State private var moving = false
    @State private var moveError: String?
    @State private var needsNewCheck = false

    var body: some View {
        NavigationStack {
            List {
                switch result {
                case .reading:
                    Section { originalName }
                    ProgressView("Reading archive…")
                case .verified(let archive):
                    verified(archive)
                case .locked:
                    Section { originalName }
                    Section {
                        Label("A password is required to verify this archive.", systemImage: "lock")
                        openButton
                    }
                case .failed(let message):
                    Section { originalName }
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .accessibilityIdentifier("recognition-error")
                        Button("Retry", action: retry)
                    }
                }
            }
            .modifier(WorkspaceListSurface())
            .navigationTitle("Identify Archive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(moving)
                        .accessibilityIdentifier("recognition-cancel")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 510, minHeight: 380)
        #else
        .presentationDetents(horizontalSizeClass == .compact ? [.medium, .large] : [.large])
        #endif
        .interactiveDismissDisabled(moving)
        .task(id: attempt) {
            do {
                let archive = try await ArchiveService().open(request.url, limits: limits)
                if !Task.isCancelled { result = .verified(archive) }
            } catch let error as ArchiveError where error.needsArchivePassword {
                if !Task.isCancelled { result = .locked }
            } catch {
                if !Task.isCancelled { result = .failed(error.localizedDescription) }
            }
        }
    }

    private var originalName: some View {
        LabeledContent("Original Name", value: request.name)
            .accessibilityIdentifier("recognition-original-name")
    }

    private func verified(_ archive: ArchiveManifest) -> some View {
        let suggested = ArchiveNames.correctedName(for: archive)
        let format = archive.compression.flatMap { $0 == archive.format ? nil : $0 }
            .map { "\(archive.format.description) · \($0.description)" } ?? archive.format.description
        return Group {
            Section {
                originalName
                LabeledContent("Detected Format", value: format)
                    .accessibilityIdentifier("recognition-format")
                if let suggested {
                    LabeledContent("Suggested Name", value: suggested)
                        .accessibilityIdentifier("recognition-suggested-name")
                }
            } footer: {
                if suggested != nil {
                    Text("Renaming preserves the file contents. It may change which app opens the file by default.")
                }
            }
            Section {
                openButton
                if let suggested, !needsNewCheck {
                    Button("Rename and Open", systemImage: "pencil") {
                        rename(archive, to: suggested)
                    }
                    .accessibilityIdentifier("recognition-rename")
                }
                if moving { ProgressView("Renaming…") }
                if let moveError {
                    Text(moveError).foregroundStyle(.secondary)
                        .accessibilityIdentifier("recognition-error")
                }
                if needsNewCheck { Button("Identify Again", action: retry) }
            }
            .disabled(moving)
        }
    }

    private var openButton: some View {
        Button("Open Archive", systemImage: "archivebox") { open(request.url, false) }
            .accessibilityIdentifier("recognition-open")
    }

    private func retry() {
        needsNewCheck = false
        moveError = nil
        result = .reading
        attempt += 1
    }

    private func rename(_ archive: ArchiveManifest, to name: String) {
        moving = true
        moveError = nil
        Task {
            defer { moving = false }
            do {
                try await FileWorkspace().rename(archive, to: name, access: request.folder.location)
                open(request.folder.item(name), true)
            } catch ArchiveError.changed {
                moveError = String(localized: "The file changed after identification. Identify it again before renaming.")
                needsNewCheck = true
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                moveError = String(localized: "That name is already in use in this folder.")
            } catch {
                moveError = error.localizedDescription
            }
        }
    }
}

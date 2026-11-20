import AetherUnzipKit
import SwiftUI
#if os(macOS)
import QuickLookUI
#else
import QuickLook
#endif

struct FilePreview: View {
    struct Request: Identifiable, Sendable {
        let entry: ArchiveEntry
        let name: String
        let suffix: String
        var id: ArchiveEntry.ID { entry.id }

        init?(entry: ArchiveEntry, name: String, capabilities: ArchiveCapabilities) {
            guard entry.kind == .file, entry.isExtractable(supporting: capabilities) else { return nil }
            let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
            guard PreviewCache.supports(suffix) else { return nil }
            self.entry = entry
            self.name = name
            self.suffix = suffix
        }
    }

    private enum Phase {
        case password(String?), loading, loaded(PreviewFile), limited(UInt64), failed(String)
    }

    let archive: ArchiveManifest
    let request: Request
    let limits: ExtractionOptions.Limits
    let extract: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CachePreferences.previewLimitKey) private var previewLimit = CachePreferences.defaultPreviewLimit
    @State private var phase: Phase
    @State private var password = ""
    @State private var passwordTask: Task<Void, Never>?

    init(archive: ArchiveManifest, request: Request, limits: ExtractionOptions.Limits,
         extract: @escaping () -> Void) {
        self.archive = archive
        self.request = request
        self.limits = limits
        self.extract = extract
        _phase = State(initialValue: request.entry.isEncrypted && !archive.hasOpeningPassphrase
                       ? .password(nil) : .loading)
    }

    private var maximumPreviewBytes: UInt64 {
        CachePreferences.bytes(for: previewLimit, choices: CachePreferences.previewLimits,
                               fallback: CachePreferences.defaultPreviewLimit)
    }

    private var exceedsPreviewLimit: Bool {
        request.entry.size.map { $0 > maximumPreviewBytes } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                WorkspaceGlyph(symbol: "doc.text", tint: .teal)
                Text(request.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .modifier(WorkspaceHeaderLayout())
            switch exceedsPreviewLimit ? .limited(maximumPreviewBytes) : phase {
            case .password(let error):
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enter the archive password to preview this file.")
                    WorkspacePasswordField(title: "Password", password: $password, identifier: "preview-password",
                                           autoFocus: true, invalid: error != nil, submit: unlock)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    Button("Preview", action: unlock)
                        .modifier(WorkspaceButton(prominent: true))
                        .disabled(password.isEmpty)
                }
                .frame(maxWidth: 340)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView("Preparing preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let file):
                NativeFilePreview(file: file)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .limited(let maximumBytes):
                ContentUnavailableView {
                    Label("Preview Unavailable", systemImage: "doc")
                } description: {
                    VStack(spacing: 4) {
                        Text("This file exceeds the preview limits.")
                        if let size = request.entry.size {
                            Text("File size · \(formattedBytes(size))")
                                .accessibilityIdentifier("preview-file-size")
                        }
                        Text("Preview limit · \(maximumBytes >> 20) MiB")
                            .accessibilityIdentifier("preview-capacity-limit")
                    }
                } actions: {
                    Button("Extract This File", systemImage: "arrow.down.to.line", action: extract)
                        .modifier(WorkspaceButton(prominent: true))
                        .accessibilityIdentifier("extract-preview-file")
                }
            case .failed(let message):
                ContentUnavailableView("Preview Unavailable", systemImage: "doc",
                                       description: Text(message))
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 380)
        #endif
        .task {
            if !exceedsPreviewLimit && (!request.entry.isEncrypted || archive.hasOpeningPassphrase) {
                await load(passphrase: nil)
            }
        }
        .onDisappear {
            passwordTask?.cancel()
            passwordTask = nil
            password = ""
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let passphrase = password
        password = ""
        phase = .loading
        passwordTask?.cancel()
        passwordTask = Task { await load(passphrase: passphrase) }
    }

    private func load(passphrase: String?) async {
        let maximumBytes = maximumPreviewBytes
        let worker = Task.detached(priority: .userInitiated) { [archive, request, limits] in
            try Task.checkCancellation()
            let file = try await PreviewCache.shared.create(suffix: request.suffix)
            let handle = try FileHandle(forWritingTo: file.url)
            do {
                try await ArchiveService().streamEntry(request.entry.id, from: archive,
                    maximumBytes: maximumBytes, passphrase: passphrase, limits: limits) { bytes in
                    try handle.write(contentsOf: bytes)
                }
                try handle.close()
                try Task.checkCancellation()
                return file
            } catch {
                try? handle.close()
                throw error
            }
        }
        do {
            let file = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            phase = .loaded(file)
        } catch {
            guard !Task.isCancelled else { return }
            switch error as? ArchiveError {
            case .incorrectPassphrase, .encrypted:
                phase = .password(error.localizedDescription)
            case .limitExceeded:
                phase = .limited(maximumBytes)
            default:
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

#if os(macOS)
private struct NativeFilePreview: NSViewRepresentable {
    let file: PreviewFile

    func makeCoordinator() -> PreviewFile { file }

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: "Quick Look could not start.")
        }
        view.autostarts = true
        view.previewItem = file.url as NSURL
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: PreviewFile) {
        (view as? QLPreviewView)?.close()
    }
}
#else
private struct NativeFilePreview: UIViewControllerRepresentable {
    let file: PreviewFile

    func makeCoordinator() -> DataSource { DataSource(file: file) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class DataSource: NSObject, QLPreviewControllerDataSource {
        let file: PreviewFile

        init(file: PreviewFile) { self.file = file }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem { file.url as NSURL }
    }
}
#endif

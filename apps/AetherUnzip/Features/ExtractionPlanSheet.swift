import AetherUnzipKit
import SwiftUI
import UniformTypeIdentifiers

struct ExtractionPlanSheet: View {
    let draft: ExtractionDraft
    let inspect: (Bool) async throws -> ([ExtractionItem], [ExtractionIssue])
    let submit: (ExtractionRun) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folder: BrowserFolder?
    @State private var mode: ExtractionMode
    @State private var conflict: ExtractionOptions.ConflictPolicy
    @State private var choosingFolder = false
    @State private var folderError: String?
    @State private var usePasswords = false
    @State private var inspectedWithLibrary = false
    @State private var loading = true
    @State private var inspecting = 0
    @State private var errorMessage: String?
    @State private var items: [ExtractionItem] = []
    @State private var issues: [ExtractionIssue] = []
    @State private var showAll = false

    init(draft: ExtractionDraft,
         inspect: @escaping (Bool) async throws -> ([ExtractionItem], [ExtractionIssue]),
         submit: @escaping (ExtractionRun) -> Void) {
        self.draft = draft
        self.inspect = inspect
        self.submit = submit
        _folder = State(initialValue: draft.destination)
        _mode = State(initialValue: draft.mode)
        _conflict = State(initialValue: draft.conflict)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(draft.title).font(.headline).lineLimit(2).truncationMode(.middle)
                    } icon: {
                        WorkspaceGlyph(symbol: draft.isBatch ? "archivebox.fill" : "doc.zipper", tint: .teal)
                    }
                    if !issues.isEmpty { skippedArchives }
                }
                destination
                options
                inspection
                if draft.isBatch { batchOptions }
            }
            .modifier(WorkspaceListSurface())
            .modifier(WorkspaceCanvas())
            .safeAreaInset(edge: .bottom, spacing: 0) { confirmation }
            .navigationTitle("Extract")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 540)
        #endif
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                folder = BrowserFolder(location: WorkspaceAccess(url))
                folderError = nil
            case .failure(let error):
                folderError = error.localizedDescription
            }
        }
        .task(id: inspecting) { await load() }
    }

    private var destination: some View {
        Section("Destination") {
            Button {
                choosingFolder = true
            } label: {
                HStack {
                    Label {
                        Text(folder?.breadcrumb ?? String(localized: "Choose Folder…"))
                            .lineLimit(2).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    Spacer()
                    if folder != nil {
                        Text("Change").font(.subheadline).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .accessibilityIdentifier("extraction-choose-folder")
            Menu {
                if let origin = draft.origin {
                    Button("Archive’s Folder", systemImage: "folder") { select(origin) }
                }
                if let last = draft.lastDestination, last.identity != draft.origin?.identity,
                   last.identity != BrowserFolder.extractionDocuments.identity {
                    Button(last.breadcrumb, systemImage: "clock") { select(last) }
                }
                Button("App Documents", systemImage: "internaldrive") { select(.extractionDocuments) }
            } label: {
                Label("Locations", systemImage: "folder.badge.gearshape")
            }
            .accessibilityIdentifier("extraction-locations")
            if let folderError { Text(folderError).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var options: some View {
        Section {
            Picker("Layout", selection: $mode) {
                ForEach(ExtractionMode.allCases.filter { $0 != .stripTopLevel || canStrip }, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("extraction-layout")
            Picker("Existing Files", selection: $conflict) {
                ForEach(ExtractionOptions.ConflictPolicy.allCases, id: \.self) {
                    Text($0.settingsTitle).tag($0)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("extraction-conflicts")
        } footer: {
            Text(mode.detail)
            if conflict == .replace {
                Label("Existing files with the same name will be overwritten.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var inspection: some View {
        if loading {
            Section { ProgressView("Reading archive…") }
        } else if let errorMessage {
            Section { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
        } else if draft.isBatch && !items.isEmpty {
            Section {
                ForEach(items.prefix(showAll ? items.count : 3)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.archive.displayName).font(.subheadline).lineLimit(1)
                        outputPath(for: item)
                        Text(placementDetail(for: item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if items.count > 3 {
                    Button(showAll ? "Show Fewer Archives" : "Show All Archives") { showAll.toggle() }
                }
            } header: {
                Text("Output Preview")
            } footer: {
                if items.contains(where: { $0.layout.placement(for: mode)?.folderName != nil }) {
                    Text("If a folder with this name exists, a numbered folder will be created.")
                }
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !loading, let item = items.first {
                if draft.isBatch {
                    if let folder { Label(folder.breadcrumb, systemImage: "folder").font(.subheadline) }
                } else {
                    outputPath(for: item)
                    Text(placementDetail(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("extraction-placement-detail")
                    if item.layout.placement(for: mode)?.folderName != nil {
                        Text("If a folder with this name exists, a numbered folder will be created.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button(conflict == .replace ? "Extract and Replace" : "Extract", action: confirm)
                .modifier(WorkspaceButton(prominent: true))
                .disabled(folder == nil || loading || items.isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirm-extraction-plan")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func outputPath(for item: ExtractionItem) -> some View {
        let suggested = item.layout.placement(for: mode)?.folderName
        let visibleFolder = suggested ?? (mode == .direct ? item.layout.commonDirectory : nil)
        let path = folder.map { ([$0.breadcrumb] + [visibleFolder].compactMap { $0 }).joined(separator: " › ") }
        return HStack(spacing: 8) {
            Image(systemName: "folder").accessibilityHidden(true)
            Text(path ?? String(localized: "Choose a destination to see the output path."))
                .lineLimit(2).truncationMode(.middle)
                .accessibilityIdentifier("extraction-output-path")
        }
        .font(.subheadline)
    }

    private func placementDetail(for item: ExtractionItem) -> String {
        let placement = item.layout.placement(for: mode)
        switch mode {
        case .smart:
            if let name = placement?.stripRoot { return String(localized: "Keep the archive’s top folder “\(name)”.") }
            if let name = placement?.folderName { return String(localized: "Group the contents in “\(name)”.") }
            return String(localized: "Place the file directly in the destination.")
        case .direct, .separateFolder:
            return mode.detail
        case .stripTopLevel:
            guard let name = placement?.stripRoot else { return mode.detail }
            return String(localized: "Remove “\(name)” and extract its contents directly.")
        }
    }

    @ViewBuilder private var batchOptions: some View {
        Section {
            Toggle("Try Saved Passwords", isOn: $usePasswords)
                .accessibilityIdentifier("batch-extraction-passwords")
                .onChange(of: usePasswords) { _, _ in
                    if usePasswords && issues.contains(where: \.needsPassword) || !usePasswords && inspectedWithLibrary {
                        inspecting += 1
                    }
                }
        } footer: {
            Text("Uses passwords in your library for locked archives. Failed archives appear in Activity.")
        }
    }

    private var skippedArchives: some View {
        DisclosureGroup {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.name).font(.subheadline.weight(.medium))
                    Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Label {
                Text("\(issues.count) will be skipped").font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("extraction-skipped")
    }

    private var canStrip: Bool {
        !items.isEmpty && items.allSatisfy { $0.layout.canStripTopLevel }
    }

    private func select(_ chosen: BrowserFolder) {
        folderError = nil
        folder = chosen
    }

    private func confirm() {
        guard let folder, !loading, !items.isEmpty else { return }
        submit(.init(items: items, issues: issues, inputURLs: draft.inputURLs, destination: folder,
                     mode: mode, conflict: conflict,
                     isBatch: draft.isBatch, choosePassword: draft.choosePassword, usePasswordLibrary: usePasswords))
    }

    private func load() async {
        loading = true
        errorMessage = nil
        let usingLibrary = usePasswords
        do {
            let result = try await inspect(usingLibrary)
            guard !Task.isCancelled else { return }
            (items, issues) = result
            inspectedWithLibrary = usingLibrary
            if mode == .stripTopLevel, !canStrip { mode = .smart }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        if !Task.isCancelled { loading = false }
    }
}

import AetherUnzipKit
import SwiftUI
import UniformTypeIdentifiers

enum DestinationPolicy: Int, CaseIterable {
    case choose, documents

    var title: String {
        switch self {
        case .choose: "Ask each time"
        case .documents: "App Documents"
        }
    }
}

struct WorkspaceView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case archives = "Archives"
        case tasks = "Tasks"
        case settings = "Settings"
        var id: Self { self }
        var icon: String {
            switch self {
            case .archives: "archivebox"
            case .tasks: "list.bullet.rectangle"
            case .settings: "gearshape"
            }
        }
    }

    private struct Request {
        let manifest: ArchiveManifest
        let selection: Set<ArchiveEntry.ID>?

        var needsPassword: Bool {
            !manifest.hasOpeningPassphrase && manifest.entries.contains { entry in
                entry.isEncrypted && (selection?.contains(entry.id) ?? true)
            }
        }
    }

    private struct PasswordRequest: Identifiable {
        let id = UUID()
        let extraction: Request
        let directory: URL
    }

    private struct NestedPasswordRequest: Identifiable {
        let id = UUID()
        let entry: ArchiveEntry
        let retrying: Bool
        let parentPassphrase: String?
    }

    private struct OpeningPasswordRequest {
        let urls: [URL]
        let profile: FormatProfile?
        var message: String? = nil
    }

    @Bindable var model: AppModel
    @State private var page: Page? = .archives
    @State private var showPicker = false
    @State private var choosingProfile = false
    @State private var archiveProfile: FormatProfile?
    @State private var profileConfirmation: ProfileConfirmation?
    @State private var loadingProfile = false
    @State private var request: Request?
    @State private var openingPassword: OpeningPasswordRequest?
    @State private var passwordRequest: PasswordRequest?
    @State private var retryPassword: PasswordRequest?
    @State private var nestedPassword: NestedPasswordRequest?
    @State private var retryNested: NestedPasswordRequest?
    @AppStorage("conflictPolicy") private var conflict = ExtractionOptions.ConflictPolicy.fail
    @AppStorage("destinationPolicy") private var destination = DestinationPolicy.choose
    @AppStorage("entryLimitGiB") private var entryLimitGiB = 4
    @AppStorage("totalLimitGiB") private var totalLimitGiB = 16
    @AppStorage("entryCountLimit") private var entryCountLimit = 10000
    @AppStorage("depthLimit") private var depthLimit = 32
    @AppStorage("expansionLimit") private var expansionLimit = 1000

    private struct ProfileConfirmation: Identifiable {
        let id = UUID()
        let name: String
        let profile: FormatProfile
    }

    private var limits: ExtractionOptions.Limits {
        var value = ExtractionOptions.Limits()
        value.maxEntryBytes = UInt64(clamping: max(1, entryLimitGiB)) << 30
        value.maxTotalBytes = UInt64(clamping: max(1, totalLimitGiB)) << 30
        value.maxEntries = UInt64(clamping: max(1, entryCountLimit))
        value.maxPathDepth = UInt32(clamping: max(1, depthLimit))
        value.maxExpansionRatio = UInt32(clamping: max(1, expansionLimit))
        return value
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in
                NavigationLink(value: item) { Label(item.rawValue, systemImage: item.icon) }
            }
            .navigationTitle("AetherUnzip")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 175, ideal: 200)
            #endif
        } detail: {
            Group {
                switch page ?? .archives {
                case .archives: archivePage
                case .tasks: TasksView(model: model)
                case .settings:
                    SettingsView(conflict: $conflict, destination: $destination,
                                 entryLimitGiB: $entryLimitGiB, totalLimitGiB: $totalLimitGiB,
                                 entryCountLimit: $entryCountLimit, depthLimit: $depthLimit,
                                 expansionLimit: $expansionLimit)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: openPicker) {
                        Label("Open Archive", systemImage: "folder.badge.plus")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.loading || loadingProfile)
                    .accessibilityIdentifier("open-archive")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(action: openProfilePicker) {
                        Label("Open with Format Profile…", systemImage: "doc.badge.gearshape")
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.loading || loadingProfile)
                    .accessibilityIdentifier("open-format-profile")
                }
            }
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: choosingProfile ? [.json] : request == nil ? [.item] : [.folder],
                      allowsMultipleSelection: request == nil && !choosingProfile && archiveProfile == nil) { result in
            let pending = request
            let isProfile = choosingProfile
            let profile = archiveProfile
            request = nil
            choosingProfile = false
            archiveProfile = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if let pending {
                    start(pending, at: url)
                } else if isProfile {
                    loadProfile(url)
                } else {
                    page = .archives
                    openArchive(urls, profile: profile)
                }
            case .failure(let error): model.error = error.localizedDescription
            }
        } onCancellation: {
            request = nil
            choosingProfile = false
            archiveProfile = nil
        }
        .sheet(item: $profileConfirmation, onDismiss: {
            if archiveProfile != nil { showPicker = true }
        }) { confirmation in
            VStack(alignment: .leading, spacing: 16) {
                Label("Format Profile", systemImage: "doc.badge.gearshape")
                    .font(.headline)
                Text(confirmation.name).textSelection(.enabled)
                Text("Payload format: \(confirmation.profile.expectedFormat.description)")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { profileConfirmation = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Choose Archive…") {
                        archiveProfile = confirmation.profile
                        profileConfirmation = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("choose-profile-archive")
                }
            }
            .padding(24)
            #if os(macOS)
            .frame(minWidth: 380)
            #endif
        }
        .sheet(item: $passwordRequest) { pending in
            PasswordPrompt(archiveName: pending.extraction.manifest.displayName, actionTitle: "Extract") { value in
                passwordRequest = nil
                run(pending.extraction, at: pending.directory, passphrase: value)
            }
        }
        .sheet(item: $nestedPassword) { pending in
            if pending.retrying && pending.entry.isEncrypted {
                NestedPasswordPrompt(entry: pending.entry.path,
                                     hasParentPassword: pending.parentPassphrase != nil ||
                                         model.manifest?.hasOpeningPassphrase == true) { parent, child in
                    nestedPassword = nil
                    openNested(pending.entry, passphrase: parent ?? pending.parentPassphrase,
                               childPassphrase: child, prompting: false)
                }
            } else {
                PasswordPrompt(archiveName: pending.entry.path, actionTitle: "Open Archive") { value in
                    nestedPassword = nil
                    openNested(pending.entry, passphrase: pending.entry.isEncrypted ? value : nil,
                               childPassphrase: pending.entry.isEncrypted ? nil : value, prompting: false)
                }
            }
        }
        .alert("AetherUnzip", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            if let retry = retryPassword {
                Button("Try Again") {
                    model.error = nil
                    retryPassword = nil
                    passwordRequest = retry
                }
            }
            if let retry = retryNested {
                Button("Retry Opening Archive") {
                    model.error = nil
                    retryNested = nil
                    nestedPassword = retry
                }
            }
            Button("OK", role: .cancel) {
                model.error = nil
                retryPassword = nil
                retryNested = nil
            }
        } message: {
            Text(model.error ?? "")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.current != nil || model.notice != nil {
                TaskBanner(model: model)
            }
        }
    }

    @ViewBuilder private var archivePage: some View {
        if let pending = openingPassword {
            PasswordPrompt(archiveName: pending.urls.first?.lastPathComponent ?? "7z",
                           actionTitle: "Open Archive", errorMessage: pending.message,
                           working: model.loading, cancel: {
                               model.cancelOpening()
                               openingPassword = nil
                           }) { value in
                openArchive(pending.urls, profile: pending.profile, passphrase: value)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Open Archive")
        } else if model.loading {
            VStack(spacing: 16) {
                ProgressView("Reading archive…")
                Button("Cancel", action: model.cancelOpening)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Archives")
        } else if let archive = model.manifest {
            ArchivePreview(archive: archive, selection: $model.selection,
                           busy: model.current != nil, limits: limits, close: model.closeArchive,
                           openNested: { openNested($0) }) { ids in
                let pending = Request(manifest: archive, selection: ids)
                if destination == .documents {
                    do {
                        let target = URL.documentsDirectory.appending(path: "Extracted Archives", directoryHint: .isDirectory)
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        start(pending, at: target)
                    } catch {
                        model.error = error.localizedDescription
                    }
                } else {
                    request = pending
                    showPicker = true
                }
            }
            .id(model.archiveID)
        } else {
            HomeView(recents: model.recents, open: openPicker,
                     reopen: { item in
                         model.reopen(item) { urls, profile in openArchive(urls, profile: profile) }
                     }, remove: model.remove)
        }
    }

    private func openArchive(_ urls: [URL], profile: FormatProfile?, passphrase: String? = nil) {
        model.open(urls, profile: profile, limits: limits, passphrase: passphrase) { failure in
            if let failure {
                if openingPassword == nil {
                    openingPassword = OpeningPasswordRequest(urls: urls, profile: profile)
                }
                openingPassword?.message = failure == .incorrectPassphrase ? failure.localizedDescription : nil
            } else {
                openingPassword = nil
            }
        }
    }

    private func openNested(_ entry: ArchiveEntry, passphrase: String? = nil,
                            childPassphrase: String? = nil, prompting: Bool = true) {
        retryNested = nil
        if prompting && entry.isEncrypted && model.manifest?.hasOpeningPassphrase != true {
            nestedPassword = NestedPasswordRequest(entry: entry, retrying: false, parentPassphrase: nil)
            return
        }
        model.openNested(entry, limits: limits, passphrase: passphrase, childPassphrase: childPassphrase) {
            retryNested = NestedPasswordRequest(entry: entry, retrying: true, parentPassphrase: passphrase)
        }
    }

    private func openPicker() {
        openingPassword = nil
        request = nil
        archiveProfile = nil
        choosingProfile = false
        showPicker = true
    }

    private func openProfilePicker() {
        openingPassword = nil
        request = nil
        archiveProfile = nil
        choosingProfile = true
        showPicker = true
    }

    private func loadProfile(_ url: URL) {
        loadingProfile = true
        Task {
            defer { loadingProfile = false }
            do {
                let profile = try await ArchiveService().loadFormatProfile(url)
                profileConfirmation = ProfileConfirmation(name: url.lastPathComponent, profile: profile)
            } catch {
                model.error = error.localizedDescription
            }
        }
    }

    private func start(_ request: Request, at url: URL) {
        if request.needsPassword {
            passwordRequest = PasswordRequest(extraction: request, directory: url)
        } else {
            run(request, at: url)
        }
    }

    private func run(_ request: Request, at url: URL, passphrase: String? = nil) {
        retryPassword = nil
        model.extract(request.manifest, to: url, ids: request.selection,
                      options: .init(conflictPolicy: conflict, limits: limits,
                                     passphrase: passphrase)) {
            retryPassword = PasswordRequest(extraction: request, directory: url)
        }
    }
}

private struct PasswordPrompt: View {
    let archiveName: String
    let actionTitle: LocalizedStringKey
    var errorMessage: String? = nil
    var working = false
    var cancel: (() -> Void)? = nil
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Archive Password", systemImage: "lock")
                .font(.headline)
            Text(archiveName).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("archive-password-error")
            }
            SecureField("Password", text: $passphrase)
                .focused($focused)
                .onSubmit(confirm)
                .disabled(working)
                .accessibilityIdentifier("archive-password")
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) {
                    if let cancel { cancel() } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || passphrase.isEmpty)
                    .accessibilityIdentifier("submit-archive-password")
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !working, !passphrase.isEmpty else { return }
        let value = passphrase
        passphrase = ""
        submit(value)
    }
}

private struct NestedPasswordPrompt: View {
    let entry: String
    let hasParentPassword: Bool
    let submit: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var parentPassword = ""
    @State private var childPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Archive Passwords", systemImage: "lock")
                .font(.headline)
            Text(entry).foregroundStyle(.secondary)
            SecureField(hasParentPassword ? "Containing archive password (optional)"
                                           : "Containing archive password", text: $parentPassword)
            SecureField("Nested archive password (if required)", text: $childPassword)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Open Archive") {
                    submit(parentPassword.isEmpty ? nil : parentPassword,
                           childPassword.isEmpty ? nil : childPassword)
                }
                .buttonStyle(.borderedProminent)
                .disabled((!hasParentPassword && parentPassword.isEmpty) ||
                          (parentPassword.isEmpty && childPassword.isEmpty))
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
    }
}

struct HomeView: View {
    let recents: [RecentArchive]
    let open: () -> Void
    let reopen: (RecentArchive) -> Void
    let remove: (RecentArchive) -> Void

    var body: some View {
        Group {
            if recents.isEmpty {
                ContentUnavailableView {
                    Label("Open an archive", systemImage: "archivebox")
                } description: {
                    Text("Browse files inside an archive and extract them to a folder you choose.")
                } actions: {
                    Button("Open Archive", action: open).buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section("Recently opened") {
                        ForEach(recents) { item in
                            Button { reopen(item) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).foregroundStyle(.primary)
                                        Text("\(item.format) · \(formattedBytes(item.size))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "archivebox").foregroundStyle(.tint)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from Recents", role: .destructive) { remove(item) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Archives")
    }
}

func formattedBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

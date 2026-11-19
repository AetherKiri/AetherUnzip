import AetherUnzipKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

enum DestinationPolicy: Int, CaseIterable {
    case choose, documents

    var title: String {
        switch self {
        case .choose: String(localized: "Ask each time")
        case .documents: String(localized: "App Documents")
        }
    }
}

struct WorkspaceView: View {
    private enum Page: CaseIterable, Identifiable {
        case archives, recent, tasks, settings

        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .archives: "Files"
            case .recent: "Recents"
            case .tasks: "Tasks"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .archives: "folder"
            case .recent: "clock"
            case .tasks: "list.bullet.rectangle"
            case .settings: "gearshape"
            }
        }
    }

    private struct Request {
        let manifest: ArchiveManifest
        let selection: Set<ArchiveEntry.ID>?
        let sourceAccess: WorkspaceAccess?

        var needsPassword: Bool {
            !manifest.hasOpeningPassphrase && manifest.entries.contains { entry in
                entry.isEncrypted && (selection?.contains(entry.id) ?? true)
            }
        }
    }

    private struct PasswordRequest: Identifiable {
        let id = UUID()
        let extraction: Request
        let directory: BrowserFolder
        var subfolder: String? = nil
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
        let origin: BrowserFolder?
        let action: ArchiveFileAction
        var message: String? = nil
        var retryCount = 0
    }

    @Bindable var model: AppModel
    @State private var files = FileBrowserModel()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var page: Page? = .archives
    @State private var showPicker = false
    @State private var choosingProfile = false
    @State private var addingLocation = false
    @State private var preparingOutput = false
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
        workspace
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: choosingProfile ? [.json] : (request != nil || addingLocation ? [.folder] : [.item]),
                      allowsMultipleSelection: request == nil && !choosingProfile && !addingLocation && archiveProfile == nil) { result in
            let pending = request
            let isProfile = choosingProfile
            let isLocation = addingLocation
            let profile = archiveProfile
            request = nil
            choosingProfile = false
            addingLocation = false
            archiveProfile = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if let pending {
                    start(pending, at: BrowserFolder(location: WorkspaceAccess(url)))
                } else if isLocation {
                    addFileLocation(url)
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
            addingLocation = false
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
                run(pending.extraction, at: pending.directory, subfolder: pending.subfolder, passphrase: value)
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
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { if page != .tasks { taskBanner } }
        #endif
    }

    @ViewBuilder private var taskBanner: some View {
        if model.current != nil || model.notice != nil {
            TaskBanner(model: model, openOutput: revealOutput)
        }
    }

    @ViewBuilder private var workspace: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact {
            TabView(selection: $page) {
                mobileArchiveWorkspace
                    .tabItem { Label(Page.archives.title, systemImage: Page.archives.icon) }
                    .tag(Optional(Page.archives))
                workspaceNavigation { recentPage }
                    .tabItem { Label(Page.recent.title, systemImage: Page.recent.icon) }
                    .tag(Optional(Page.recent))
                workspaceNavigation(showTaskBanner: false) { TasksView(model: model) }
                    .tabItem { Label(Page.tasks.title, systemImage: Page.tasks.icon) }
                    .tag(Optional(Page.tasks))
                workspaceNavigation { settingsPage }
                    .tabItem { Label(Page.settings.title, systemImage: Page.settings.icon) }
                    .tag(Optional(Page.settings))
            }
        } else {
            splitWorkspace
        }
        #else
        splitWorkspace
        #endif
    }

    private var splitWorkspace: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    ForEach(Page.allCases) { item in
                        NavigationLink(value: item) { Label(item.title, systemImage: item.icon) }
                    }
                }
                Section("Locations") {
                    Button {
                        model.leaveArchive()
                        files.show(.documents)
                        page = .archives
                    } label: {
                        Label("My Files", systemImage: "internaldrive")
                    }
                    .buttonStyle(.plain)
                    ForEach(files.favorites) { saved in
                        Button {
                            Task {
                                do {
                                    try await files.show(saved)
                                    model.leaveArchive()
                                    page = .archives
                                } catch { model.error = error.localizedDescription }
                            }
                        } label: {
                            Label(saved.name, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Location", role: .destructive) { files.remove(saved) }
                        }
                    }
                    Button("Add Folder Location…", systemImage: "folder.badge.plus", action: pickLocation)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar-add-folder-location")
                }
            }
            .navigationTitle("AetherUnzip")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 175, ideal: 200)
            #endif
        } detail: {
            Group {
                switch page ?? .archives {
                #if os(iOS)
                case .archives: mobileArchiveWorkspace
                case .recent: workspaceNavigation { recentPage }
                case .tasks: workspaceNavigation(showTaskBanner: false) { TasksView(model: model) }
                case .settings: workspaceNavigation { settingsPage }
                #else
                case .archives: archivePage
                case .recent: recentPage
                case .tasks: TasksView(model: model)
                case .settings: settingsPage
                #endif
                }
            }
            #if os(macOS)
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
            #endif
        }
    }

    private var settingsPage: some View {
        SettingsView(conflict: $conflict, destination: $destination,
                     entryLimitGiB: $entryLimitGiB, totalLimitGiB: $totalLimitGiB,
                     entryCountLimit: $entryCountLimit, depthLimit: $depthLimit,
                     expansionLimit: $expansionLimit)
    }

    #if os(iOS)
    @ViewBuilder private var mobileArchiveWorkspace: some View {
        if model.manifest != nil && !model.loading && openingPassword == nil {
            archivePage.safeAreaInset(edge: .bottom, spacing: 0) { taskBanner }
        } else {
            workspaceNavigation { archivePage }
        }
    }

    private func workspaceNavigation<Content: View>(showTaskBanner: Bool = true,
                                                     @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content().safeAreaInset(edge: .bottom, spacing: 0) { if showTaskBanner { taskBanner } }
        }
    }
    #endif

    @ViewBuilder private var archivePage: some View {
        if let pending = openingPassword {
            PasswordPrompt(archiveName: pending.urls.first?.lastPathComponent ?? String(localized: "Archive"),
                           actionTitle: "Open Archive", errorMessage: pending.message,
                           working: model.loading, retryCount: pending.retryCount, cancel: {
                               model.cancelOpening()
                               openingPassword = nil
                           }) { value in
                openArchive(pending.urls, profile: pending.profile, passphrase: value,
                            origin: pending.origin, action: pending.action)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(WorkspaceCanvas())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        } else if model.loading {
            VStack(spacing: 16) {
                ProgressView("Reading archive…")
                Button("Cancel", action: model.cancelOpening)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Archives")
        } else if let archive = model.manifest {
            #if os(iOS)
            ArchivePreview(archive: archive, selection: $model.selection, browsing: $model.browsing,
                           busy: model.current != nil || preparingOutput, limits: limits, close: model.closeArchive,
                           openNested: { openNested($0) }, extract: { extract(archive, ids: $0) },
                           nearbyDestination: model.archiveOrigin?.name,
                           extractNearby: { ids, action in extractNearby(archive, ids: ids, action: action) })
                .id(model.archiveID)
            #else
            ArchivePreview(archive: archive, selection: $model.selection,
                           busy: model.current != nil || preparingOutput, limits: limits, close: model.closeArchive,
                           openNested: { openNested($0) }, extract: { extract(archive, ids: $0) },
                           nearbyDestination: model.archiveOrigin?.name,
                           extractNearby: { ids, action in extractNearby(archive, ids: ids, action: action) })
                .id(model.archiveID)
            #endif
        } else {
            FileBrowserView(model: files, openPicker: openPicker, openProfile: openProfilePicker,
                            addLocation: pickLocation,
                            openArchive: { urls, origin, action in
                                openArchive(urls, profile: nil, origin: origin, action: action)
                            }, showError: { model.error = $0 })
        }
    }

    private var recentPage: some View {
        RecentArchivesView(recents: model.recents, reopen: { item in
            model.reopen(item) { urls, profile, origin in
                if let origin { files.show(origin) }
                openArchive(urls, profile: profile, origin: origin)
            }
        }, remove: model.remove)
    }

    private func extract(_ archive: ArchiveManifest, ids: Set<ArchiveEntry.ID>?) {
        let pending = Request(manifest: archive, selection: ids, sourceAccess: model.archiveOrigin?.location)
        if destination == .documents {
            preparingOutput = true
            Task {
                defer { preparingOutput = false }
                do {
                    let target = BrowserFolder.documents.child("Extracted Archives")
                    try await Task.detached(priority: .utility) {
                        try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
                    }.value
                    preparingOutput = false
                    start(pending, at: target)
                } catch { model.error = error.localizedDescription }
            }
        } else {
            request = pending
            showPicker = true
        }
    }

    private func extractNearby(_ archive: ArchiveManifest, ids: Set<ArchiveEntry.ID>?, action: ArchiveFileAction) {
        guard let origin = model.archiveOrigin, model.current == nil, !preparingOutput else { return }
        let pending = Request(manifest: archive, selection: ids, sourceAccess: origin.location)
        let subfolder = action == .extractToNewFolder
            ? ArchiveNames.extractionFolder(for: archive.displayName) : nil
        start(pending, at: origin, subfolder: subfolder)
    }

    private func openArchive(_ urls: [URL], profile: FormatProfile?, passphrase: String? = nil,
                             origin: BrowserFolder? = nil, action: ArchiveFileAction = .browse) {
        page = .archives
        let previous = model.archiveID
        model.open(urls, profile: profile, limits: limits, passphrase: passphrase, origin: origin) { failure in
            if let failure {
                if openingPassword == nil {
                    openingPassword = OpeningPasswordRequest(urls: urls, profile: profile, origin: origin, action: action)
                }
                openingPassword?.message = failure == .incorrectPassphrase ? failure.localizedDescription : nil
                if failure == .incorrectPassphrase { openingPassword?.retryCount += 1 }
            } else {
                openingPassword = nil
                if action != .browse, model.archiveID != previous, let archive = model.manifest {
                    extractNearby(archive, ids: nil, action: action)
                }
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
        addingLocation = false
        showPicker = true
    }

    private func openProfilePicker() {
        openingPassword = nil
        request = nil
        archiveProfile = nil
        choosingProfile = true
        addingLocation = false
        showPicker = true
    }

    private func pickLocation() {
        request = nil
        archiveProfile = nil
        choosingProfile = false
        addingLocation = true
        showPicker = true
    }

    private func addFileLocation(_ url: URL) {
        Task {
            do {
                try await files.add(url)
                model.leaveArchive()
                page = .archives
            } catch { model.error = error.localizedDescription }
        }
    }

    private func revealOutput() {
        guard let output = model.lastOutput else { return }
        model.notice = nil
        model.leaveArchive()
        files.show(output)
        page = .archives
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

    private func start(_ request: Request, at directory: BrowserFolder, subfolder: String? = nil) {
        if request.needsPassword {
            passwordRequest = PasswordRequest(extraction: request, directory: directory, subfolder: subfolder)
        } else {
            run(request, at: directory, subfolder: subfolder)
        }
    }

    private func run(_ request: Request, at directory: BrowserFolder, subfolder: String? = nil,
                     passphrase: String? = nil) {
        guard model.current == nil, !preparingOutput else { return }
        if let subfolder {
            preparingOutput = true
            Task {
                defer { preparingOutput = false }
                do {
                    let target = try await FileWorkspace().makeUniqueFolder(named: subfolder,
                        in: directory.url, access: directory.location)
                    begin(request, at: directory.child(target.lastPathComponent), passphrase: passphrase)
                } catch { model.error = error.localizedDescription }
            }
        } else {
            begin(request, at: directory, passphrase: passphrase)
        }
    }

    private func begin(_ request: Request, at directory: BrowserFolder, passphrase: String?) {
        retryPassword = nil
        model.extract(request.manifest, to: directory, ids: request.selection,
                      options: .init(conflictPolicy: conflict, limits: limits,
                                     passphrase: passphrase), sourceAccess: request.sourceAccess) {
            retryPassword = PasswordRequest(extraction: request, directory: directory)
        }
    }

}

private struct PasswordPrompt: View {
    let archiveName: String
    let actionTitle: LocalizedStringKey
    var errorMessage: String? = nil
    var working = false
    var retryCount = 0
    var cancel: (() -> Void)? = nil
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceHeading(title: String(localized: "Archive Password"), symbol: "lock", tint: .orange,
                             detail: archiveName, singleLine: true)
            WorkspacePasswordField(title: "Password", password: $passphrase, identifier: "archive-password",
                                   autoFocus: true, invalid: errorMessage != nil, submit: confirm)
                .id(retryCount)
                .disabled(working)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("archive-password-error")
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) {
                    if let cancel { cancel() } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: confirm)
                    .modifier(WorkspaceButton(prominent: true))
                    .disabled(working || passphrase.isEmpty)
                    .accessibilityIdentifier("submit-archive-password")
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
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
            WorkspaceHeading(title: String(localized: "Archive Passwords"), symbol: "lock", tint: .orange,
                             detail: entry, singleLine: true)
            WorkspacePasswordField(title: hasParentPassword ? "Parent Password (Optional)" : "Parent Password",
                                   password: $parentPassword, identifier: "parent-archive-password", submit: confirm)
            WorkspacePasswordField(title: "Nested Archive Password", password: $childPassword,
                                   identifier: "nested-archive-password", submit: confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Open Archive", action: confirm)
                    .modifier(WorkspaceButton(prominent: true))
                    .disabled(!canOpen)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
    }

    private var canOpen: Bool {
        (hasParentPassword || !parentPassword.isEmpty) && (!parentPassword.isEmpty || !childPassword.isEmpty)
    }

    private func confirm() {
        guard canOpen else { return }
        submit(parentPassword.isEmpty ? nil : parentPassword, childPassword.isEmpty ? nil : childPassword)
    }
}

struct RecentArchivesView: View {
    let recents: [RecentArchive]
    let reopen: (RecentArchive) -> Void
    let remove: (RecentArchive) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: String(localized: "Recents"),
                             detail: recents.isEmpty ? nil : String(localized: "\(recents.count) archives"))
                .modifier(WorkspaceHeaderLayout())
            if recents.isEmpty {
                ContentUnavailableView("No Recent Archives", systemImage: "clock")
            } else {
                List {
                    ForEach(recents) { item in recentRow(item) }
                }
                .modifier(WorkspaceListSurface())
            }
        }
        .modifier(WorkspaceCanvas())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
        .contextMenu {
            Button("Remove from Recents", role: .destructive) { remove(item) }
        }
    }
}

func formattedBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

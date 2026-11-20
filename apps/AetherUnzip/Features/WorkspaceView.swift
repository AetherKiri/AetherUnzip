import AetherUnzipKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

enum DestinationPolicy: Int, CaseIterable {
    case choose, documents, nearby

    var title: String {
        switch self {
        case .choose: String(localized: "Ask each time")
        case .documents: String(localized: "App Documents")
        case .nearby: String(localized: "Archive’s Folder")
        }
    }
}

struct WorkspaceView: View {
    private enum Page: CaseIterable, Identifiable {
        case archives, passwords, activity, settings

        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .archives: "Files"
            case .passwords: "Passwords"
            case .activity: "Activity"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .archives: "folder"
            case .passwords: "key"
            case .activity: "clock.arrow.circlepath"
            case .settings: "gearshape"
            }
        }
    }

    private struct PasswordRequest: Identifiable {
        let id = UUID()
        let extraction: ExtractionRun
        var existingOutput: BrowserFolder? = nil
    }

    private struct ConflictRetry {
        let extraction: ExtractionRun
        let password: PasswordChoice
        let output: BrowserFolder?
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
    @AppStorage(CachePreferences.nestedLimitKey) private var nestedLimit = CachePreferences.defaultNestedLimit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var extractionDraft: ExtractionDraft?
    @State private var confirmedExtraction: ExtractionRun?
    @State private var lastExtractionDestination: BrowserFolder?
    @State private var openingPassword: OpeningPasswordRequest?
    @State private var passwordRequest: PasswordRequest?
    @State private var retryPassword: PasswordRequest?
    @State private var retryConflict: ConflictRetry?
    @State private var nestedPassword: NestedPasswordRequest?
    @State private var retryNested: NestedPasswordRequest?
    @AppStorage("conflictPolicy") private var conflict = ExtractionOptions.ConflictPolicy.keepBoth
    @AppStorage("destinationPolicy") private var destination = DestinationPolicy.nearby
    @AppStorage("entryLimitGiB") private var entryLimitGiB = AppSafetyLimits.defaults.entryGiB
    @AppStorage("totalLimitGiB") private var totalLimitGiB = AppSafetyLimits.defaults.totalGiB
    @AppStorage("entryCountLimit") private var entryCountLimit = AppSafetyLimits.defaults.entries
    @AppStorage("depthLimit") private var depthLimit = AppSafetyLimits.defaults.depth
    @AppStorage("expansionLimit") private var expansionLimit = AppSafetyLimits.defaults.expansion

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
                      allowedContentTypes: choosingProfile ? [.json] : (addingLocation ? [.folder] : [.item]),
                      allowsMultipleSelection: !choosingProfile && !addingLocation && archiveProfile == nil) { result in
            let isProfile = choosingProfile
            let isLocation = addingLocation
            let profile = archiveProfile
            choosingProfile = false
            addingLocation = false
            archiveProfile = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if isLocation {
                    addFileLocation(url)
                } else if isProfile {
                    loadProfile(url)
                } else {
                    page = .archives
                    let groups = ArchiveService().archiveGroups(in: urls)
                    if groups.count > 1 {
                        prepareBatch(groups, origin: nil)
                    } else {
                        openArchive(urls, profile: profile)
                    }
                }
            case .failure(let error): model.error = error.localizedDescription
            }
        } onCancellation: {
            choosingProfile = false
            addingLocation = false
            archiveProfile = nil
        }
        .sheet(item: $extractionDraft, onDismiss: {
            guard let extraction = confirmedExtraction else { return }
            confirmedExtraction = nil
            start(extraction)
        }) { draft in
            ExtractionPlanSheet(draft: draft, inspect: { try await inspect(draft, usePasswords: $0) }) { extraction in
                confirmedExtraction = extraction
                extractionDraft = nil
            }
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
            PasswordPrompt(archiveName: pending.extraction.items.first?.archive.displayName ?? "",
                           actionTitle: "Extract",
                           library: model.passwords) { choice in
                passwordRequest = nil
                run(pending.extraction, password: choice, existingOutput: pending.existingOutput)
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
                PasswordPrompt(archiveName: pending.entry.path, actionTitle: "Open Archive") { choice in
                    guard case .manual(let value, _) = choice else { return }
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
            if let plan = retryConflict {
                Button("Keep Existing and Retry") {
                    model.error = nil
                    retryConflict = nil
                    run(plan.extraction, password: plan.password, existingOutput: plan.output, conflictOverride: .skip)
                }
            }
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
                retryConflict = nil
            }
        } message: {
            Text(model.error ?? "")
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { if page != .activity { taskBanner } }
        #endif
    }

    private var taskBanner: some View {
        let visible = model.current != nil || model.notice != nil
        return ZStack {
            if visible {
                TaskBanner(model: model, openOutput: revealOutput)
                    .transition(reduceMotion ? .identity : WorkspaceMotion.bottomInset)
            }
        }
        .animation(reduceMotion ? nil : WorkspaceMotion.layout, value: visible)
    }

    @ViewBuilder private var workspace: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact {
            TabView(selection: $page) {
                mobileArchiveWorkspace
                    .tabItem { Label(Page.archives.title, systemImage: Page.archives.icon) }
                    .tag(Optional(Page.archives))
                workspaceNavigation { passwordPage }
                    .tabItem { Label(Page.passwords.title, systemImage: Page.passwords.icon) }
                    .tag(Optional(Page.passwords))
                workspaceNavigation(showTaskBanner: false) { activityPage }
                    .tabItem { Label(Page.activity.title, systemImage: Page.activity.icon) }
                    .tag(Optional(Page.activity))
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
                            .accessibilityIdentifier("workspace-sidebar-\(item)")
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
                case .passwords: workspaceNavigation { passwordPage }
                case .activity: workspaceNavigation(showTaskBanner: false) { activityPage }
                case .settings: workspaceNavigation { settingsPage }
                #else
                case .archives: archivePage
                case .passwords: passwordPage
                case .activity: activityPage
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
                     safetyLimits: AppSafetyLimits(entryGiB: entryLimitGiB, totalGiB: totalLimitGiB,
                                                  entries: entryCountLimit, depth: depthLimit,
                                                  expansion: expansionLimit)) { values in
            entryLimitGiB = values.entryGiB
            totalLimitGiB = values.totalGiB
            entryCountLimit = values.entries
            depthLimit = values.depth
            expansionLimit = values.expansion
        }
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
                           working: model.loading, retryCount: pending.retryCount, library: model.passwords, cancel: {
                               model.cancelOpening()
                               openingPassword = nil
            }) { choice in
                openArchive(pending.urls, profile: pending.profile, password: choice,
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
                           extractWithPassword: { extract(archive, ids: $0, choosePassword: true) },
                           nearbyDestination: model.archiveOrigin?.name,
                           extractNearby: { ids, action in extract(archive, ids: ids, action: action) })
                .id(model.archiveID)
            #else
            ArchivePreview(archive: archive, selection: $model.selection,
                           busy: model.current != nil || preparingOutput, limits: limits, close: model.closeArchive,
                           openNested: { openNested($0) }, extract: { extract(archive, ids: $0) },
                           extractWithPassword: { extract(archive, ids: $0, choosePassword: true) },
                           nearbyDestination: model.archiveOrigin?.name,
                           extractNearby: { ids, action in extract(archive, ids: ids, action: action) })
                .id(model.archiveID)
            #endif
        } else {
            FileBrowserView(model: files, limits: limits, openPicker: openPicker, openProfile: openProfilePicker,
                            addLocation: pickLocation,
                            openArchive: { urls, origin, action in
                                openArchive(urls, profile: nil, origin: origin, action: action)
                            }, extractSelected: { urls, origin in
                                let groups = ArchiveService().archiveGroups(in: urls)
                                if let group = groups.first, groups.count == 1 {
                                    openArchive(group, profile: nil, origin: origin, action: .extractSmart)
                                } else {
                                    prepareBatch(groups, origin: origin)
                                }
                            }, showError: { model.error = $0 })
        }
    }

    private var passwordPage: some View {
        PasswordLibraryView(library: model.passwords, refreshVersion: model.passwordLibraryVersion)
    }

    private var activityPage: some View {
        ActivityView(model: model) { item in
            model.reopen(item) { urls, profile, origin in
                if let origin { files.show(origin) }
                openArchive(urls, profile: profile, origin: origin)
            }
        }
    }

    private func extract(_ archive: ArchiveManifest, ids: Set<ArchiveEntry.ID>?,
                         choosePassword: Bool = false, action: ArchiveFileAction = .browse) {
        guard model.current == nil, !preparingOutput else { return }
        let origin = model.archiveOrigin
        let mode: ExtractionMode = switch action {
        case .browse, .extractSmart: .smart
        case .extractHere: .direct
        case .extractToNewFolder: .separateFolder
        }
        extractionDraft = .init(source: .archive(archive, ids), origin: origin,
            destination: action == .browse ? preferredDestination(origin) : origin,
            lastDestination: lastExtractionDestination, mode: mode, conflict: conflict,
            access: [origin?.location].compactMap { $0 }, choosePassword: choosePassword)
    }

    private func prepareBatch(_ groups: [[URL]], origin: BrowserFolder?) {
        guard model.current == nil, !preparingOutput, !groups.isEmpty else { return }
        let access = origin.map { [$0.location] } ?? groups.flatMap { $0 }.map(WorkspaceAccess.init)
        extractionDraft = .init(source: .batch(groups), origin: origin,
            destination: preferredDestination(origin), lastDestination: lastExtractionDestination,
            mode: .smart, conflict: conflict, access: access)
    }

    private func preferredDestination(_ origin: BrowserFolder?) -> BrowserFolder? {
        switch destination {
        case .choose: nil
        case .documents: .extractionDocuments
        case .nearby: origin ?? .extractionDocuments
        }
    }

    private func inspect(_ draft: ExtractionDraft, usePasswords: Bool) async throws
        -> ([ExtractionItem], [ExtractionIssue]) {
        let service = ArchiveService()
        let limits = self.limits
        switch draft.source {
        case .archive(let archive, let selection):
            let layout = try await service.extractionLayout(for: archive, selecting: selection, limits: limits)
            return ([.init(archive: archive, selection: selection, access: draft.access, layout: layout)], [])
        case .batch(let groups):
            var items: [ExtractionItem] = []
            var issues: [ExtractionIssue] = []
            for urls in groups {
                try Task.checkCancellation()
                do {
                    let archive = try await model.inspectArchive(urls, limits: limits, usePasswordLibrary: usePasswords)
                    guard archive.capabilities.contains(.extract) else { throw ArchiveError.unsupported }
                    let layout = try await service.extractionLayout(for: archive, limits: limits)
                    items.append(.init(archive: archive, selection: nil, access: draft.access, layout: layout))
                } catch {
                    try Task.checkCancellation()
                    issues.append(.init(name: urls.first?.lastPathComponent ?? String(localized: "Archive"),
                        reason: error.localizedDescription,
                        needsPassword: (error as? ArchiveError)?.needsArchivePassword == true))
                }
            }
            return (items, issues)
        }
    }

    private func openArchive(_ urls: [URL], profile: FormatProfile?, password: PasswordChoice = .automatic,
                             origin: BrowserFolder? = nil, action: ArchiveFileAction = .browse) {
        page = .archives
        let previous = model.archiveID
        model.open(urls, profile: profile, limits: limits, password: password, origin: origin) { failure in
            if let failure {
                if openingPassword == nil {
                    openingPassword = OpeningPasswordRequest(urls: urls, profile: profile, origin: origin, action: action)
                }
                if case .library = password {
                    openingPassword?.message = String(localized: "None of the saved passwords could unlock this archive.")
                } else {
                    openingPassword?.message = failure == .incorrectPassphrase ? failure.localizedDescription : nil
                }
                if openingPassword?.message != nil { openingPassword?.retryCount += 1 }
            } else {
                openingPassword = nil
                if action != .browse, model.archiveID != previous, let archive = model.manifest {
                    extract(archive, ids: nil, action: action)
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
        let maximumStagedBytes = CachePreferences.bytes(for: nestedLimit, choices: CachePreferences.nestedLimits,
                                                       fallback: CachePreferences.defaultNestedLimit)
        model.openNested(entry, limits: limits, maximumStagedBytes: maximumStagedBytes,
                         passphrase: passphrase, childPassphrase: childPassphrase) {
            retryNested = NestedPasswordRequest(entry: entry, retrying: true, parentPassphrase: passphrase)
        }
    }

    private func openPicker() {
        openingPassword = nil
        archiveProfile = nil
        choosingProfile = false
        addingLocation = false
        showPicker = true
    }

    private func openProfilePicker() {
        openingPassword = nil
        archiveProfile = nil
        choosingProfile = true
        addingLocation = false
        showPicker = true
    }

    private func pickLocation() {
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

    private func start(_ extraction: ExtractionRun) {
        guard model.current == nil, !preparingOutput, let item = extraction.items.first else { return }
        lastExtractionDestination = extraction.destination
        if extraction.isBatch || (!item.needsPassword && !extraction.choosePassword) {
            run(extraction)
        } else if extraction.choosePassword {
            passwordRequest = PasswordRequest(extraction: extraction)
        } else {
            preparingOutput = true
            Task {
                let remembered = await model.rememberedPassword(for: item.archive)
                preparingOutput = false
                if let remembered {
                    run(extraction, password: .saved(remembered, remember: false))
                } else {
                    passwordRequest = PasswordRequest(extraction: extraction)
                }
            }
        }
    }

    private func run(_ extraction: ExtractionRun, password: PasswordChoice = .automatic,
                     existingOutput: BrowserFolder? = nil,
                     conflictOverride: ExtractionOptions.ConflictPolicy? = nil) {
        guard model.current == nil, !preparingOutput else { return }
        retryPassword = nil
        retryConflict = nil
        model.extract(extraction, limits: limits, password: password, existingOutput: existingOutput,
                      conflictOverride: conflictOverride) { failure, output in
            if failure?.needsArchivePassword == true {
                retryPassword = PasswordRequest(extraction: extraction, existingOutput: output)
            } else if failure == .conflict && (conflictOverride ?? extraction.conflict) == .fail {
                retryConflict = ConflictRetry(extraction: extraction, password: password, output: output)
            }
            files.reload()
        }
    }

}

private struct PasswordPrompt: View {
    let archiveName: String
    let actionTitle: LocalizedStringKey
    var errorMessage: String? = nil
    var working = false
    var retryCount = 0
    var library: PasswordLibrary? = nil
    var cancel: (() -> Void)? = nil
    let submit: (PasswordChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var remember = true
    @State private var saved: [PasswordLabel] = []

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
            if library != nil {
                Toggle("Save Password for This Archive", isOn: $remember)
                    .font(.subheadline)
                    .disabled(working)
                    .accessibilityIdentifier("remember-archive-password")
                if !saved.isEmpty {
                    Menu {
                        Button("Try All Saved Passwords") { choose(.library(remember: remember)) }
                            .accessibilityIdentifier("try-password-library")
                        Divider()
                        ForEach(saved) { entry in
                            Button(entry.title) { choose(.saved(entry.id, remember: remember)) }
                        }
                    } label: {
                        Label("Choose from Password Library", systemImage: "key")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(working)
                    .accessibilityIdentifier("choose-saved-password")
                }
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
        .task {
            if let library { saved = (try? await library.labels()) ?? [] }
        }
    }

    private func confirm() {
        guard !working, !passphrase.isEmpty else { return }
        choose(.manual(passphrase, remember: library != nil && remember))
    }

    private func choose(_ choice: PasswordChoice) {
        guard !working else { return }
        passphrase = ""
        submit(choice)
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

func formattedBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

import AetherUnzipKit
import Foundation
import Observation

struct RecentArchive: Identifiable, Codable {
    let id: String
    let name: String
    let format: String
    let size: UInt64
    let bookmark: Data?
    let volumeBookmarks: [Data]?
    let profile: FormatProfile?
    var locationBookmark: Data?
    var relativeFiles: [[String]]?
}

struct TaskRecord: Identifiable, Codable {
    enum State: String, Codable {
        case running = "Extracting"
        case success = "Completed"
        case failed = "Failed"
        case skipped = "Skipped"
        case cancelled = "Cancelled"
    }

    let id: UUID
    let archive: String
    var destination: String
    let started: Date
    var state: State
    var details: String?
}

private struct ParentArchive {
    let archive: ArchiveManifest
    let selection: Set<ArchiveEntry.ID>
    #if os(iOS)
    let browsing: ArchiveBrowsing
    #endif
}

@MainActor @Observable
final class AppModel {
    var manifest: ArchiveManifest?
    var selection: Set<ArchiveEntry.ID> = []
    #if os(iOS)
    var browsing = ArchiveBrowsing()
    #endif
    var recents: [RecentArchive] = []
    var history: [TaskRecord] = []
    var current: TaskRecord?
    var progress: ExtractionProgress?
    var loading = false
    var cancelling = false
    var error: String?
    var notice: String?
    private(set) var noticeIsPartial = false
    private(set) var batchPosition: (index: Int, total: Int)?
    private(set) var archiveOrigin: BrowserFolder?
    private(set) var lastOutput: BrowserFolder?
    private(set) var batchResult: BatchResult?
    private(set) var noticeIsBatch = false

    private let service = ArchiveService()
    let passwords = PasswordLibrary()
    private(set) var passwordLibraryVersion = 0
    private var extraction: Task<Void, Never>?
    private var opening: Task<Void, Never>?
    private var parents: [ParentArchive] = []
    private(set) var archiveID = UUID()

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "recentArchives") {
            recents = (try? JSONDecoder().decode([RecentArchive].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: "taskHistory") {
            history = (try? JSONDecoder().decode([TaskRecord].self, from: data)) ?? []
        }
    }

    func open(_ urls: [URL], profile: FormatProfile? = nil, limits: ExtractionOptions.Limits,
              password: PasswordChoice = .automatic, origin: BrowserFolder? = nil,
              finished: @escaping (ArchiveError?) -> Void) {
        opening?.cancel()
        loading = true
        error = nil
        notice = nil
        opening = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                let archive = try await unlock(urls, profile: profile, limits: limits, password: password)
                let bookmarks = await Task.detached(priority: .utility) {
                    let archiveBookmarks = archive.sourceURLs.compactMap { createBookmark(for: $0) }
                    let locationBookmark = origin.flatMap { $0.isDocuments ? nil : try? $0.location.bookmark() }
                    return (archiveBookmarks, locationBookmark)
                }.value
                guard !Task.isCancelled else { return }
                parents.removeAll()
                manifest = archive
                archiveOrigin = origin
                archiveID = UUID()
                selection = []
                #if os(iOS)
                browsing = ArchiveBrowsing()
                #endif
                let id = archive.url.absoluteString
                recents.removeAll { $0.id == id }
                let single = archive.sourceURLs.count == 1
                let complete = bookmarks.0.count == archive.sourceURLs.count
                let relativeFiles = origin.flatMap { folder in
                    folder.isDocuments || bookmarks.1 != nil
                        ? archive.sourceURLs.map { folder.components + [$0.lastPathComponent] } : nil
                }
                recents.insert(.init(id: id, name: archive.displayName,
                                     format: archive.format.description,
                                     size: archive.compressedSize,
                                     bookmark: single ? bookmarks.0.first : nil,
                                     volumeBookmarks: !single && complete ? bookmarks.0 : nil,
                                     profile: archive.profile, locationBookmark: bookmarks.1,
                                     relativeFiles: relativeFiles), at: 0)
                recents = Array(recents.prefix(12))
                persist(recents, for: "recentArchives")
                finished(nil)
            } catch {
                guard !Task.isCancelled else { return }
                if let failure = error as? ArchiveError,
                   failure.needsArchivePassword {
                    finished(failure)
                } else {
                    finished(nil)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func unlock(_ urls: [URL], profile: FormatProfile?, limits: ExtractionOptions.Limits,
                        password: PasswordChoice) async throws -> ArchiveManifest {
        func read(_ passphrase: String?) async throws -> ArchiveManifest {
            if let profile {
                guard urls.count == 1, let url = urls.first else { throw ArchiveError.invalidInput }
                return try await service.open(url, profile: profile, limits: limits, passphrase: passphrase)
            }
            return try await service.open(urls, limits: limits, passphrase: passphrase)
        }

        if case .automatic = password {
            do { return try await read(nil) }
            catch let error as ArchiveError where error.needsArchivePassword {
                guard (try? await passwords.hasArchiveAssociations()) == true,
                      let fingerprint = try? await service.archiveFingerprint(for: urls, profile: profile),
                      let id = try? await passwords.rememberedID(for: fingerprint),
                      let candidate = try? await passwords.candidates(for: .saved(id, remember: false)).first
                else { throw error }
                try Task.checkCancellation()
                do { return try await read(candidate.value) }
                catch let rejected as ArchiveError where rejected.needsArchivePassword { throw error }
            }
        }

        var rejection = ArchiveError.incorrectPassphrase
        for candidate in try await passwords.candidates(for: password) {
            try Task.checkCancellation()
            do {
                let archive = try await read(candidate.value)
                await remember(candidate, for: archive)
                return archive
            } catch let error as ArchiveError where error.needsArchivePassword {
                rejection = error
            }
        }
        throw rejection
    }

    func inspectArchive(_ urls: [URL], limits: ExtractionOptions.Limits,
                        usePasswordLibrary: Bool) async throws -> ArchiveManifest {
        do { return try await unlock(urls, profile: nil, limits: limits, password: .automatic) }
        catch let error as ArchiveError where error.needsArchivePassword && usePasswordLibrary {
            return try await unlock(urls, profile: nil, limits: limits, password: .library(remember: false))
        }
    }

    func rememberedPassword(for archive: ArchiveManifest) async -> UUID? {
        guard !archive.isNested, (try? await passwords.hasArchiveAssociations()) == true,
              let fingerprint = try? await service.archiveFingerprint(for: archive) else { return nil }
        return try? await passwords.rememberedID(for: fingerprint)
    }

    private func remember(_ candidate: PasswordCandidate, for archive: ArchiveManifest) async {
        guard candidate.remember, !Task.isCancelled else { return }
        let fingerprint = try? await service.archiveFingerprint(for: archive)
        guard !Task.isCancelled else { return }
        do {
            try await passwords.save(candidate.value, title: archive.displayName, fingerprint: fingerprint)
            passwordLibraryVersion += 1
        } catch { self.error = error.localizedDescription }
    }

    func openNested(_ entry: ArchiveEntry, limits: ExtractionOptions.Limits, maximumStagedBytes: UInt64,
                    passphrase: String? = nil,
                    childPassphrase: String? = nil,
                    authenticationFailed: @escaping () -> Void) {
        guard let parent = manifest, !loading else { return }
        opening?.cancel()
        loading = true
        error = nil
        #if os(iOS)
        let previous = ParentArchive(archive: parent, selection: selection, browsing: browsing)
        #else
        let previous = ParentArchive(archive: parent, selection: selection)
        #endif
        opening = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                let archive = try await service.openNested(entry.id, in: parent, passphrase: passphrase,
                                                           childPassphrase: childPassphrase,
                                                           maximumStagedBytes: maximumStagedBytes, limits: limits)
                guard !Task.isCancelled else { return }
                parents.append(previous)
                manifest = archive
                archiveID = UUID()
                selection = []
                #if os(iOS)
                browsing = ArchiveBrowsing()
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                if let failure = error as? ArchiveError,
                   failure == .incorrectPassphrase || failure == .encrypted {
                    authenticationFailed()
                }
                self.error = error.localizedDescription
            }
        }
    }

    func cancelOpening() {
        opening?.cancel()
        opening = nil
        loading = false
    }

    func reopen(_ item: RecentArchive, openArchive: ([URL], FormatProfile?, BrowserFolder?) -> Void) {
        if let relative = item.relativeFiles, let first = relative.first,
           relative.allSatisfy({ !$0.isEmpty && $0.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") } }) {
            do {
                var folder = if let bookmark = item.locationBookmark {
                    BrowserFolder(location: try WorkspaceAccess.restore(bookmark))
                } else { BrowserFolder.documents }
                folder.components = Array(first.dropLast())
                let root = folder.location.url
                let urls = relative.map { components in components.reduce(root) { $0.appending(path: $1) } }
                openArchive(urls, item.profile, folder)
                return
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        let bookmarks = item.volumeBookmarks ?? [item.bookmark].compactMap { $0 }
        guard !bookmarks.isEmpty else {
            error = String(localized: "Access to this archive has expired. Select it again with Open Archive.")
            return
        }
        do {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI]
            #endif
            let urls = try bookmarks.map { data in
                var stale = false
                return try URL(resolvingBookmarkData: data, options: options, relativeTo: nil,
                               bookmarkDataIsStale: &stale)
            }
            openArchive(urls, item.profile, nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ item: RecentArchive) {
        recents.removeAll { $0.id == item.id }
        persist(recents, for: "recentArchives")
    }

    func closeArchive() {
        let parent = parents.popLast()
        manifest = parent?.archive
        if parent == nil { archiveOrigin = nil }
        selection = parent?.selection ?? []
        #if os(iOS)
        browsing = parent?.browsing ?? ArchiveBrowsing()
        #endif
        archiveID = UUID()
    }

    func leaveArchive() {
        parents.removeAll()
        closeArchive()
    }

    func extract(_ run: ExtractionRun, limits: ExtractionOptions.Limits,
                 password: PasswordChoice, existingOutput: BrowserFolder?,
                 conflictOverride: ExtractionOptions.ConflictPolicy?,
                 retry: BatchResult.Entry? = nil,
                 finished: @escaping (ArchiveError?, BrowserFolder?) -> Void) {
        guard extraction == nil,
              let name = retry?.record.archive ?? run.items.first?.archive.displayName ?? run.issues.first?.name
        else { return }
        current = record(for: name, at: run.destination)
        progress = nil
        cancelling = false
        notice = nil
        noticeIsPartial = false
        noticeIsBatch = run.isBatch
        lastOutput = nil
        let policy = conflictOverride ?? run.conflict
        if run.isBatch && retry == nil {
            batchResult = .init(inputs: run.inputURLs, destination: run.destination, mode: run.mode,
                                conflict: policy, usePasswordLibrary: run.usePasswordLibrary)
        }

        extraction = Task {
            defer {
                extraction = nil
                current = nil
                batchPosition = nil
                cancelling = false
            }
            var items = run.items
            if let retry {
                do {
                    let archive: ArchiveManifest
                    if case .automatic = password {
                        archive = try await inspectArchive(retry.urls, limits: limits,
                                                           usePasswordLibrary: run.usePasswordLibrary)
                    } else {
                        do {
                            archive = try await service.open(retry.urls, limits: limits)
                        } catch let error as ArchiveError where error.needsArchivePassword {
                            archive = try await unlock(retry.urls, profile: nil, limits: limits, password: password)
                        }
                    }
                    guard archive.capabilities.contains(.extract) else { throw ArchiveError.unsupported }
                    let layout = try await service.extractionLayout(for: archive, limits: limits)
                    items = [.init(archive: archive, selection: nil, access: retry.access, layout: layout)]
                } catch {
                    if !Task.isCancelled {
                        var record = retry.record
                        record.state = .failed
                        record.details = error.localizedDescription
                        saveBatchEntry(.init(record: record, urls: retry.urls, access: retry.access,
                                             output: retry.output,
                                             needsPassword: isPasswordFailure(error),
                                             reservedOutput: retry.reservedOutput))
                    }
                    showBatchOutcome(cancelled: Task.isCancelled)
                    finished(nil, nil)
                    return
                }
            }
            var completed = 0
            var cancelled = false
            var preparedBase = false
            for issue in run.issues {
                var skipped = record(for: issue.name, at: run.destination)
                skipped.state = .skipped
                skipped.details = issue.reason
                saveBatchEntry(.init(record: skipped, urls: issue.urls, access: issue.access,
                                     output: nil, needsPassword: issue.needsPassword))
            }
            for (index, item) in items.enumerated() {
                var record = retry?.record ?? self.record(for: item.archive.displayName, at: run.destination)
                record.state = .running
                record.details = nil
                current = record
                progress = nil
                if run.isBatch { batchPosition = (index + 1, items.count) }
                var output = existingOutput
                var browsableOutput: BrowserFolder?
                var reservedOutput: BrowserFolder?
                var needsPassword = false
                var candidate = password
                do {
                    try Task.checkCancellation()
                    guard let placement = item.layout.placement(for: run.mode) else {
                        throw ArchiveError.invalidInput
                    }
                    if run.isBatch, policy == .replace,
                       await item.layout.wouldReplaceInput(run.inputURLs, at: run.destination.url,
                                                           placement: placement) {
                        throw ArchiveError.fileAccess(String(localized: "An output file would replace one of the selected archives."))
                    }
                    if !preparedBase {
                        try await prepareBase(run.destination)
                        preparedBase = true
                    }
                    if run.isBatch, item.needsPassword, case .automatic = password {
                        if let id = await rememberedPassword(for: item.archive) {
                            candidate = .saved(id, remember: false)
                        } else if run.usePasswordLibrary {
                            candidate = .library(remember: false)
                        } else {
                            throw ArchiveError.encrypted
                        }
                    }
                    try Task.checkCancellation()
                    if output == nil { output = try await outputFolder(for: placement, in: run.destination) }
                    if placement.folderName != nil { reservedOutput = output }
                    guard let output else { throw ArchiveError.invalidInput }
                    record.destination = output.name
                    current = record
                    let options = ExtractionOptions(conflictPolicy: policy, limits: limits, stripRoot: placement.stripRoot)
                    try await performExtraction(item, to: output, options: options, password: candidate)
                    record.state = .success
                    completed += 1
                    if run.mode == .direct, let top = item.layout.commonDirectory {
                        browsableOutput = output.child(top)
                    } else {
                        browsableOutput = output
                    }
                    if !run.isBatch {
                        lastOutput = output
                        notice = String(localized: "Extraction completed in \(output.name).")
                    }
                } catch let error where error is CancellationError || (error as? ArchiveError) == .cancelled {
                    record.state = .cancelled
                    cancelled = true
                } catch {
                    record.state = .failed
                    let failure = error as? ArchiveError
                    needsPassword = isPasswordFailure(error)
                    if failure?.needsArchivePassword == true, case .library = candidate {
                        record.details = String(localized: "None of the saved passwords could unlock this archive.")
                    } else {
                        record.details = error.localizedDescription
                    }
                    if !run.isBatch {
                        self.error = record.details
                        finished(error is PasswordLibrary.Failure ? .encrypted : failure, output)
                    }
                }
                if record.state != .success, let output, (progress?.entriesDone ?? 0) > 0 {
                    browsableOutput = output
                    if !run.isBatch {
                        lastOutput = output
                        noticeIsPartial = true
                        notice = String(localized: "Extraction stopped. Files already extracted are kept.")
                    }
                }
                if run.isBatch {
                    if let browsableOutput { record.destination = browsableOutput.breadcrumb }
                    saveBatchEntry(.init(record: record, urls: item.archive.sourceURLs, access: item.access,
                                         output: browsableOutput ?? retry?.output, needsPassword: needsPassword,
                                         reservedOutput: browsableOutput == nil ? reservedOutput : nil))
                } else {
                    recordResult(record)
                }
                if cancelled {
                    if run.isBatch {
                        for pending in items.dropFirst(index + 1) {
                            var skipped = self.record(for: pending.archive.displayName, at: run.destination)
                            skipped.state = .cancelled
                            saveBatchEntry(.init(record: skipped, urls: pending.archive.sourceURLs,
                                                 access: pending.access, output: nil, needsPassword: false))
                        }
                    }
                    break
                }
            }
            if run.isBatch {
                showBatchOutcome(cancelled: cancelled)
                finished(nil, nil)
            } else if cancelled {
                notice = String(localized: "Extraction cancelled. Files already extracted are kept.")
                finished(nil, nil)
            } else if completed > 0 {
                finished(nil, nil)
            }
        }
    }

    func retryBatchEntry(_ id: UUID, limits: ExtractionOptions.Limits, password: PasswordChoice,
                         finished: @escaping () -> Void) {
        guard let batchResult, let entry = batchResult.entries.first(where: { $0.id == id }),
              entry.canRetry else { return }
        let run = ExtractionRun(items: [], issues: [], inputURLs: batchResult.inputs,
                                destination: batchResult.destination, mode: batchResult.mode,
                                conflict: batchResult.conflict, isBatch: true, choosePassword: false,
                                usePasswordLibrary: batchResult.usePasswordLibrary)
        extract(run, limits: limits, password: password, existingOutput: entry.reservedOutput,
                conflictOverride: nil, retry: entry) { _, _ in finished() }
    }

    private func isPasswordFailure(_ error: any Error) -> Bool {
        (error as? ArchiveError)?.needsArchivePassword == true || error is PasswordLibrary.Failure
    }

    private func saveBatchEntry(_ entry: BatchResult.Entry) {
        if let index = batchResult?.entries.firstIndex(where: { $0.id == entry.id }) {
            batchResult?.entries[index] = entry
        } else {
            batchResult?.entries.append(entry)
        }
        recordResult(entry.record)
    }

    private func showBatchOutcome(cancelled: Bool) {
        guard let batchResult else { return }
        let completed = batchResult.entries.filter { $0.record.state == .success }.count
        let total = batchResult.entries.count
        if batchResult.entries.contains(where: { $0.output != nil }) { lastOutput = batchResult.destination }
        noticeIsPartial = completed != total
        if cancelled {
            notice = String(localized: "Batch cancelled. \(completed) of \(total) archives extracted.")
        } else {
            notice = String(localized: "\(completed) of \(total) archives extracted.")
        }
    }

    private func prepareBase(_ folder: BrowserFolder) async throws {
        if folder.identity == BrowserFolder.extractionDocuments.identity {
            do {
                _ = try await FileWorkspace().makeFolder(named: folder.name,
                    in: folder.url.deletingLastPathComponent(), access: folder.location)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Core opens the existing root without following symlinks.
            }
        }
    }

    private func outputFolder(for placement: ExtractionPlacement, in folder: BrowserFolder) async throws -> BrowserFolder {
        guard let name = placement.folderName else { return folder }
        let unique = try await FileWorkspace().makeUniqueFolder(named: name, in: folder.url, access: folder.location)
        return folder.child(unique.lastPathComponent)
    }

    private func performExtraction(_ item: ExtractionItem, to folder: BrowserFolder, options: ExtractionOptions,
                                   password: PasswordChoice) async throws {
        defer { withExtendedLifetime((item.access, folder.location)) {} }
        let candidates = try await passwords.candidates(for: password)
        try Task.checkCancellation()
        let task = service.extract(item.archive, to: folder.url, selecting: item.selection, options: options,
                                   passwordCandidates: candidates.map(\.value))
        let accepted = try await withTaskCancellationHandler {
            for await update in task.progress { progress = update }
            return try await task.acceptedPasswordCandidateIndex()
        } onCancel: { task.cancel() }
        if let accepted { await remember(candidates[accepted], for: item.archive) }
    }

    private func record(for name: String, at directory: BrowserFolder) -> TaskRecord {
        TaskRecord(id: UUID(), archive: name, destination: directory.name, started: .now, state: .running)
    }

    private func recordResult(_ record: TaskRecord) {
        history.removeAll { $0.id == record.id }
        history.insert(record, at: 0)
        history = Array(history.prefix(20))
        persist(history, for: "taskHistory")
    }

    func cancelExtraction() {
        guard let extraction else { return }
        cancelling = true
        extraction.cancel()
    }

    private func persist<T: Encodable>(_ value: T, for key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

private func createBookmark(for url: URL) -> Data? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    #if os(macOS)
    let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    #else
    let options: URL.BookmarkCreationOptions = []
    #endif
    return try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
}

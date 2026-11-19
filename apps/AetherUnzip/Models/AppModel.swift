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
        case cancelled = "Cancelled"
    }

    let id: UUID
    let archive: String
    let destination: String
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
    private(set) var archiveOrigin: BrowserFolder?
    private(set) var lastOutput: BrowserFolder?

    private let service = ArchiveService()
    private var extraction: ExtractionTask?
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
              passphrase: String? = nil, origin: BrowserFolder? = nil,
              finished: @escaping (ArchiveError?) -> Void) {
        opening?.cancel()
        loading = true
        error = nil
        notice = nil
        opening = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                let archive: ArchiveManifest
                if let profile {
                    guard urls.count == 1, let url = urls.first else { throw ArchiveError.invalidInput }
                    archive = try await service.open(url, profile: profile, limits: limits, passphrase: passphrase)
                } else {
                    archive = try await service.open(urls, limits: limits, passphrase: passphrase)
                }
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
                   failure == .encrypted || failure == .incorrectPassphrase {
                    finished(failure)
                } else {
                    finished(nil)
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func openNested(_ entry: ArchiveEntry, limits: ExtractionOptions.Limits, passphrase: String? = nil,
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
                                                           childPassphrase: childPassphrase, limits: limits)
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
            error = "Access to this archive has expired. Select it again with Open Archive."
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

    func extract(_ archive: ArchiveManifest, to output: BrowserFolder, ids: Set<ArchiveEntry.ID>?,
                 options: ExtractionOptions, sourceAccess: WorkspaceAccess?,
                 authenticationFailed: (() -> Void)? = nil) {
        guard extraction == nil else { return }
        let destination = output.url
        var record = TaskRecord(id: UUID(), archive: archive.displayName,
                                destination: destination.lastPathComponent, started: .now,
                                state: .running)
        current = record
        progress = nil
        cancelling = false
        notice = nil
        lastOutput = nil
        let task = service.extract(archive, to: destination, selecting: ids, options: options)
        extraction = task
        Task {
            defer { withExtendedLifetime((sourceAccess, output.location)) {} }
            for await update in task.progress { progress = update }
            do {
                try await task.value()
                record.state = .success
                lastOutput = output
                notice = "Extraction completed in \(destination.lastPathComponent)."
            } catch ArchiveError.cancelled {
                record.state = .cancelled
                notice = "Extraction cancelled. Files already extracted are kept."
            } catch {
                record.state = .failed
                record.details = error.localizedDescription
                if let error = error as? ArchiveError,
                   error == .incorrectPassphrase || error == .encrypted {
                    authenticationFailed?()
                }
                self.error = error.localizedDescription
            }
            history.insert(record, at: 0)
            history = Array(history.prefix(20))
            persist(history, for: "taskHistory")
            extraction = nil
            current = nil
            cancelling = false
        }
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

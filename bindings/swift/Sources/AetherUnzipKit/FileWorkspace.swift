import Darwin
import Foundation

/// Keeps access to one user-selected directory alive for its current consumers.
public final class WorkspaceAccess: Sendable {
    public let url: URL
    private let scoped: Bool

    public init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    public func bookmark() throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: .withSecurityScope)
        #else
        try url.bookmarkData()
        #endif
    }

    public static func restore(_ bookmark: Data) throws -> WorkspaceAccess {
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        var stale = false
        return try WorkspaceAccess(URL(resolvingBookmarkData: bookmark, options: options,
                                       relativeTo: nil, bookmarkDataIsStale: &stale))
    }
}

public struct WorkspaceFile: Identifiable, Sendable {
    public enum Kind: Sendable { case folder, file, other }

    public let name: String
    public let kind: Kind
    public let size: UInt64?
    public let modified: Date?
    public var id: String { name }
}

/// The editable text and the file revision it was read from.
public struct WorkspaceTextFile: Sendable {
    public let url: URL
    public let text: String
    fileprivate let access: WorkspaceAccess
    fileprivate let revision: FileRevision
    fileprivate let bytes: Data
}

public enum WorkspaceTextError: LocalizedError, Equatable, Sendable {
    case unsupported, tooLarge, changed

    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Only UTF-8 text files can be edited.", bundle: .module)
        case .tooLarge: String(localized: "The text editor supports files up to 1 MiB.", bundle: .module)
        case .changed: String(localized: "The file changed on disk. Reopen it before saving.", bundle: .module)
        }
    }
}

public struct FileWorkspace: Sendable {
    public enum Transfer: Sendable { case copy, move }
    private static let textLimit = 1024 * 1024
    private static let utf8BOM = Data([0xef, 0xbb, 0xbf])

    public init() {}

    public func contents(of folder: URL, access: WorkspaceAccess) async throws -> [WorkspaceFile] {
        let intent = NSFileAccessIntent.readingIntent(with: folder, options: [.withoutChanges])
        return try await coordinate([intent], accesses: [access]) { urls, _ in
            let folder = urls[0]
            try Self.requireDirectory(folder)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                             .isPackageKey, .fileSizeKey, .contentModificationDateKey]
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                               options: [.skipsHiddenFiles]).map { url in
                let values = try? url.resourceValues(forKeys: keys)
                let kind: WorkspaceFile.Kind
                if values?.isSymbolicLink == true || values?.isPackage == true { kind = .other }
                else if values?.isDirectory == true { kind = .folder }
                else if values?.isRegularFile == true { kind = .file }
                else { kind = .other }
                return WorkspaceFile(name: url.lastPathComponent, kind: kind,
                                     size: kind == .file ? values?.fileSize.map(UInt64.init(clamping:)) : nil,
                                     modified: values?.contentModificationDate)
            }
        }
    }

    public func makeFolder(named name: String, in folder: URL, access: WorkspaceAccess) async throws -> URL {
        try Self.checkName(name)
        let intent = NSFileAccessIntent.writingIntent(with: folder, options: [])
        return try await coordinate([intent], accesses: [access]) { urls, _ in
            try Self.requireDirectory(urls[0])
            let target = urls[0].appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return target
        }
    }

    /// Creates a UTF-8 file and fails if the name is already taken.
    public func makeTextFile(named name: String, in folder: URL, contents: String = "",
                             access: WorkspaceAccess) async throws -> WorkspaceTextFile {
        try Self.checkName(name)
        let bytes = try Self.textData(contents)
        let intent = NSFileAccessIntent.writingIntent(with: folder, options: [])
        return try await coordinate([intent], accesses: [access]) { urls, _ in
            try Self.requireDirectory(urls[0])
            let target = urls[0].appending(path: name, directoryHint: .notDirectory)
            try bytes.write(to: target, options: .withoutOverwriting)
            return WorkspaceTextFile(url: folder.appending(path: name, directoryHint: .notDirectory),
                                     text: contents, access: access, revision: try FileRevision(target), bytes: bytes)
        }
    }

    public func readText(at url: URL, access: WorkspaceAccess) async throws -> WorkspaceTextFile {
        let intent = NSFileAccessIntent.readingIntent(with: url, options: [.withoutChanges])
        return try await coordinate([intent], accesses: [access]) { urls, _ in
            let (bytes, revision) = try Self.readTextBytes(urls[0])
            let body = bytes.starts(with: Self.utf8BOM) ? bytes.dropFirst(Self.utf8BOM.count) : bytes
            guard let text = String(bytes: body, encoding: .utf8), Self.isText(text) else {
                throw WorkspaceTextError.unsupported
            }
            return WorkspaceTextFile(url: url, text: text, access: access, revision: revision, bytes: bytes)
        }
    }

    /// Atomically replaces a text file if it still matches the supplied snapshot.
    public func saveText(_ text: String, for file: WorkspaceTextFile) async throws -> WorkspaceTextFile {
        let bytes = try Self.textData(text, includeBOM: file.bytes.starts(with: Self.utf8BOM))
        let intent = NSFileAccessIntent.writingIntent(with: file.url, options: [.forReplacing])
        return try await coordinate([intent], accesses: [file.access]) { urls, _ in
            let url = urls[0]
            guard (try? FileRevision(url)) == file.revision else { throw WorkspaceTextError.changed }
            let (current, revision) = try Self.readTextBytes(url)
            guard revision == file.revision, current == file.bytes else { throw WorkspaceTextError.changed }
            try bytes.write(to: url, options: .atomic)
            return WorkspaceTextFile(url: file.url, text: text, access: file.access,
                                     revision: try FileRevision(url), bytes: bytes)
        }
    }

    public func makeUniqueFolder(named name: String, in folder: URL, access: WorkspaceAccess) async throws -> URL {
        try Self.checkName(name)
        let intent = NSFileAccessIntent.writingIntent(with: folder, options: [])
        return try await coordinate([intent], accesses: [access]) { urls, _ in
            let folder = urls[0]
            try Self.requireDirectory(folder)
            for version in 1...1000 {
                let target = folder.appending(path: version == 1 ? name : "\(name) \(version)",
                                              directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    return target
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
    }

    public func rename(_ url: URL, to name: String, access: WorkspaceAccess) async throws {
        try Self.checkName(name)
        if name == url.lastPathComponent { return }
        let folder = url.deletingLastPathComponent()
        let item = NSFileAccessIntent.writingIntent(with: url, options: [.forMoving])
        let parent = NSFileAccessIntent.writingIntent(with: folder, options: [])
        try await coordinate([item, parent], accesses: [access]) { urls, coordinator in
            try Self.requireDirectory(urls[1])
            let target = urls[1].appending(path: name)
            coordinator.item(at: urls[0], willMoveTo: target)
            try FileManager.default.moveItem(at: urls[0], to: target)
            coordinator.item(at: urls[0], didMoveTo: target)
        }
    }

    public func transfer(_ urls: [URL], to folder: URL, operation: Transfer,
                         sourceAccess: WorkspaceAccess, destinationAccess: WorkspaceAccess) async throws {
        // Check the entire set before mutating anything for obvious conflicts.
        let targets = urls.map { folder.appending(path: $0.lastPathComponent) }
        for (source, target) in zip(urls, targets) {
            let path = source.standardizedFileURL.pathComponents
            guard target.standardizedFileURL.pathComponents != path,
                  !folder.standardizedFileURL.pathComponents.starts(with: path) else {
                throw ArchiveError.invalidInput
            }
        }
        let items = urls.map { url in
            operation == .move ? NSFileAccessIntent.writingIntent(with: url, options: [.forMoving])
                : NSFileAccessIntent.readingIntent(with: url, options: [])
        }
        let destination = NSFileAccessIntent.writingIntent(with: folder, options: [])
        try await coordinate(items + [destination], accesses: [sourceAccess, destinationAccess]) { paths, coordinator in
            let folder = paths[items.count]
            try Self.requireDirectory(folder)
            let manager = FileManager.default
            let sources = paths.prefix(items.count)
            let targets = sources.map { folder.appending(path: $0.lastPathComponent) }
            for target in targets where (try? target.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
                throw CocoaError(.fileWriteFileExists)
            }
            for (source, target) in zip(sources, targets) {
                if operation == .move {
                    coordinator.item(at: source, willMoveTo: target)
                    try manager.moveItem(at: source, to: target)
                    coordinator.item(at: source, didMoveTo: target)
                } else {
                    try manager.copyItem(at: source, to: target)
                }
            }
        }
    }

    public func delete(_ urls: [URL], access: WorkspaceAccess) async throws {
        let items = urls.map { NSFileAccessIntent.writingIntent(with: $0, options: [.forDeleting]) }
        try await coordinate(items, accesses: [access]) { paths, _ in
            for url in paths {
                #if os(macOS)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                #else
                try FileManager.default.removeItem(at: url)
                #endif
            }
        }
    }

    private static func checkName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.utf8.contains(0), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchiveError.invalidInput
        }
    }

    private static func isText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0...8, 11...12, 14...31, 127: false
            default: true
            }
        }
    }

    private static func textData(_ text: String, includeBOM: Bool = false) throws -> Data {
        var bytes = includeBOM ? utf8BOM : Data()
        guard text.utf8.count <= textLimit - bytes.count else { throw WorkspaceTextError.tooLarge }
        guard isText(text) else { throw WorkspaceTextError.unsupported }
        bytes.append(contentsOf: text.utf8)
        return bytes
    }

    private static func readTextBytes(_ url: URL) throws -> (Data, FileRevision) {
        let revision = try FileRevision(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor == -1 {
            if errno == ELOOP { throw WorkspaceTextError.unsupported }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSURLErrorKey: url])
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ArchiveError.inputOutput }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceTextError.unsupported }
        guard info.st_size <= textLimit else { throw WorkspaceTextError.tooLarge }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, textLimit - bytes.count + 1)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= textLimit else { throw WorkspaceTextError.tooLarge }
        }
        guard try FileRevision(url) == revision else { throw WorkspaceTextError.changed }
        return (bytes, revision)
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ArchiveError.fileAccess(String(localized: "The folder is no longer available.", bundle: .module))
        }
    }

    private func coordinate<T: Sendable>(
        _ intents: [NSFileAccessIntent], accesses: [WorkspaceAccess],
        _ work: @escaping @Sendable ([URL], NSFileCoordinator) throws -> T
    ) async throws -> T {
        guard !intents.isEmpty else { throw ArchiveError.invalidInput }
        try Task.checkCancellation()
        // The accessor runs after coordination and uses this same instance for move notifications.
        nonisolated(unsafe) let coordinator = NSFileCoordinator()
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let result: T = try await withCheckedThrowingContinuation { continuation in
            coordinator.coordinate(with: intents, queue: queue) { error in
                continuation.resume(with: Result {
                    if let error { throw error }
                    return try work(intents.map(\.url), coordinator)
                })
            }
        }
        return withExtendedLifetime((coordinator, accesses)) { result }
    }
}

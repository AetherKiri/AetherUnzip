import Darwin
import Foundation

enum CachePreferences {
    static let automaticCleanupKey = "automaticallyClearPreviewCache"
    static let previewLimitKey = "previewLimitMiB"
    static let nestedLimitKey = "nestedArchiveLimitMiB"
    static let previewLimits = [8, 16, 32]
    static let nestedLimits = [64, 128, 256]
    static let defaultPreviewLimit = 32
    static let defaultNestedLimit = 256

    static func bytes(for mebibytes: Int, choices: [Int], fallback: Int) -> UInt64 {
        UInt64(choices.contains(mebibytes) ? mebibytes : fallback) << 20
    }
}

actor PreviewCache {
    static let shared = PreviewCache(temporaryDirectory: FileManager.default.temporaryDirectory)
    static let directoryName = "aetherunzip-previews"
    private static let legacyPrefix = "aetherunzip-preview-"
    private static let legacyGracePeriod: TimeInterval = 24 * 60 * 60
    private static let suffixes: Set<String> = [
        "txt", "md", "log", "csv", "tsv", "json", "yaml", "yml", "ini",
        "pdf", "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp"
    ]

    struct Usage: Sendable {
        var bytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var reclaimableCount = 0
        var removedBytes: UInt64 = 0
    }

    private let temporaryDirectory: URL
    private var root: URL { temporaryDirectory.appending(path: Self.directoryName, directoryHint: .isDirectory) }

    init(temporaryDirectory: URL) {
        self.temporaryDirectory = temporaryDirectory
    }

    nonisolated static func supports(_ suffix: String) -> Bool { suffixes.contains(suffix) }

    func create(suffix: String) throws -> PreviewFile {
        guard Self.supports(suffix) else { throw CocoaError(.fileWriteInvalidFileName) }
        return try withLockedRoot {
            let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                let error = Self.ioError()
                _ = rmdir(directory.path)
                throw error
            }
            let name = "Preview." + suffix
            do {
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Self.ioError() }
                let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard file >= 0 else { throw Self.ioError() }
                close(file)
                return PreviewFile(directory: directory, name: name, descriptor: descriptor)
            } catch {
                close(descriptor)
                _ = rmdir(directory.path)
                throw error
            }
        }
    }

    func usage(clearing: Bool = false) throws -> Usage {
        try withLockedRoot {
            var usage = Usage()
            let manager = FileManager.default
            for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where UUID(uuidString: entry.lastPathComponent) != nil {
                try inspect(entry, clearing: clearing, usage: &usage)
            }
            // Older releases did not hold a lease. Allow time for any such preview to close.
            let cutoff = Date().addingTimeInterval(-Self.legacyGracePeriod)
            for entry in try manager.contentsOfDirectory(at: temporaryDirectory,
                                                         includingPropertiesForKeys: [.contentModificationDateKey])
                where entry.lastPathComponent.hasPrefix(Self.legacyPrefix) {
                let id = entry.lastPathComponent.dropFirst(Self.legacyPrefix.count)
                guard UUID(uuidString: String(id)) != nil,
                      let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                try inspect(entry, clearing: clearing, usage: &usage)
            }
            return usage
        }
    }

    private func withLockedRoot<T>(_ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.ioError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Self.ioError() }
        try Task.checkCancellation()
        return try operation()
    }

    private func inspect(_ directory: URL, clearing: Bool, usage: inout Usage) throws {
        try Task.checkCancellation()
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return }
            throw Self.ioError()
        }
        defer { close(descriptor) }
        let available = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        if !available && errno != EWOULDBLOCK { throw Self.ioError() }

        let children: [String]
        do {
            children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
        guard children.count <= 1 else { return }
        let child = children.first
        var bytes: UInt64 = 0
        if let child {
            guard child.hasPrefix("Preview."), Self.supports(String(child.dropFirst("Preview.".count))) else { return }
            var info = stat()
            if fstatat(descriptor, child, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }
                throw Self.ioError()
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return }
            bytes = UInt64(clamping: info.st_blocks) * 512
        }
        if available && clearing {
            try Self.remove(directory, name: child, descriptor: descriptor)
            usage.removedBytes += bytes
        } else {
            usage.bytes += bytes
            if available {
                usage.reclaimableBytes += bytes
                usage.reclaimableCount += 1
            }
        }
    }

    fileprivate nonisolated static func remove(_ directory: URL, name: String?, descriptor: Int32) throws {
        if let name, unlinkat(descriptor, name, 0) != 0, errno != ENOENT { throw ioError() }
        if rmdir(directory.path) != 0, errno != ENOENT { throw ioError() }
    }

    private nonisolated static func ioError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

final class PreviewFile: Sendable {
    private let directory: URL
    private let name: String
    private let descriptor: Int32
    let url: URL

    fileprivate init(directory: URL, name: String, descriptor: Int32) {
        self.directory = directory
        self.name = name
        self.descriptor = descriptor
        self.url = directory.appending(path: name, directoryHint: .notDirectory)
    }

    deinit {
        Task.detached(priority: .utility) { [directory, name, descriptor] in
            defer { close(descriptor) }
            try? PreviewCache.remove(directory, name: name, descriptor: descriptor)
        }
    }
}

import CAetherUnzip
import Foundation

public enum ArchiveFormat: UInt32, Sendable, CustomStringConvertible {
    case unknown, zip, tar, sevenZip, rar, rar5, gzip, lz4, zstandard, xz, bzip2, cab, iso9660, lha, brotli, xp3

    public var description: String { String(cString: aether_unzip_format_name(rawValue)) }
}

public struct ArchiveCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let list = Self(rawValue: UInt32(AU_CAN_LIST))
    public static let extract = Self(rawValue: UInt32(AU_CAN_EXTRACT))
    public static let read = Self(rawValue: UInt32(AU_CAN_READ))
    public static let seek = Self(rawValue: UInt32(AU_CAN_SEEK))
    public static let requiresSeekableSource = Self(rawValue: UInt32(AU_REQUIRES_SEEKABLE_SOURCE))
    public static let encryption = Self(rawValue: UInt32(AU_SUPPORTS_ENCRYPTION))
    public static let multiVolume = Self(rawValue: UInt32(AU_SUPPORTS_MULTIVOLUME))
}

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case file, directory, unsupported }

    public let id: UInt64
    public let path: String
    public let size: UInt64?
    public let kind: Kind
    public let isEncrypted: Bool

    public var canExtract: Bool { isExtractable(supporting: []) }

    public func isExtractable(supporting capabilities: ArchiveCapabilities) -> Bool {
        kind != .unsupported && (!isEncrypted || capabilities.contains(.encryption))
    }

    init(_ entry: au_entry) {
        id = entry.index
        path = String(decoding: UnsafeRawBufferPointer(start: entry.name, count: entry.name_length),
                      as: UTF8.self)
        size = entry.size_known != 0 ? entry.size : nil
        switch Int(entry.kind) {
        case AU_ENTRY_FILE: kind = .file
        case AU_ENTRY_DIRECTORY: kind = .directory
        default: kind = .unsupported
        }
        isEncrypted = entry.encrypted != 0
    }
}

public struct ArchiveManifest: Sendable {
    public let url: URL
    public let sourceURLs: [URL]
    public let displayName: String
    public let format: ArchiveFormat
    public let compression: ArchiveFormat?
    public let isStream: Bool
    public let capabilities: ArchiveCapabilities
    public let compressedSize: UInt64
    public let entries: [ArchiveEntry]
    public let profile: FormatProfile?
    let revisions: [FileRevision]
    let nestedSource: NestedArchiveSource?
    let openingPassphrase: ArchivePassphrase?

    public var isNested: Bool { nestedSource != nil }
    public var hasOpeningPassphrase: Bool { openingPassphrase != nil }
    var coordinatedURLs: [URL] { isNested ? [] : sourceURLs }
    var decoderName: String { profile?.payloadName ?? displayName }
}

struct ArchivePassphrase: Sendable, CustomReflectable {
    let value: String

    var customMirror: Mirror { Mirror(self, unlabeledChildren: EmptyCollection<Any>()) }
}

// The source is private and each Core use is synchronous and serialized by the lock.
final class NestedArchiveSource: @unchecked Sendable {
    private let source: OpaquePointer
    private let lock = NSLock()
    let remainingDepth: UInt32
    let remainingBytes: UInt64

    init(_ source: OpaquePointer, remainingDepth: UInt32, remainingBytes: UInt64) {
        self.source = source
        self.remainingDepth = remainingDepth
        self.remainingBytes = remainingBytes
    }

    func access<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try lock.withLock { try body(source) }
    }

    deinit { aether_unzip_source_close(source) }
}

struct FileRevision: Equatable, Sendable {
    let size: UInt64
    let modified: Date?
    let device: UInt64?
    let inode: UInt64?

    init(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ArchiveError.fileAccess(error.localizedDescription)
        }
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

public struct ResourceLayer: Sendable {
    public let archive: ArchiveManifest
    public let prefix: String
    public let passphrase: String?

    public init(_ archive: ArchiveManifest, prefix: String = "", passphrase: String? = nil) {
        self.archive = archive
        self.prefix = prefix
        self.passphrase = passphrase
    }
}

public enum ResourceCollisionPolicy: Sendable {
    case strict
    case preferLast

    var coreValue: UInt32 {
        switch self {
        case .strict: UInt32(AU_RESOURCE_STRICT)
        case .preferLast: UInt32(AU_RESOURCE_PREFER_LAST)
        }
    }
}

public struct ResourceEntry: Identifiable, Sendable {
    public let path: String
    public let size: UInt64?
    public let kind: ArchiveEntry.Kind
    public let isEncrypted: Bool

    // The Core compares normalized UTF-8 bytes, including canonically equivalent names.
    public var id: [UInt8] { Array(path.utf8) }

    init(_ entry: ArchiveEntry) {
        path = entry.path
        size = entry.size
        kind = entry.kind
        isEncrypted = entry.isEncrypted
    }
}

public struct ExtractionOptions: Sendable {
    public enum ConflictPolicy: Int, CaseIterable, Sendable {
        case fail, skip, replace, keepBoth
    }

    public struct Limits: Sendable {
        public var maxEntryBytes: UInt64
        public var maxTotalBytes: UInt64
        public var maxEntries: UInt64
        public var maxPathDepth: UInt32
        public var maxExpansionRatio: UInt32

        public init() {
            let defaults = aether_unzip_options_default()
            maxEntryBytes = defaults.max_entry_bytes
            maxTotalBytes = defaults.max_total_bytes
            maxEntries = defaults.max_entries
            maxPathDepth = defaults.max_path_depth
            maxExpansionRatio = defaults.max_expansion_ratio
        }
    }

    public var conflictPolicy: ConflictPolicy
    public var limits: Limits
    /// Removes this exact shared top-level directory. Core revalidates before writing.
    public var stripRoot: String?
    /// Used for this extraction task. The SDK does not persist this value.
    public var passphrase: String?

    public init(conflictPolicy: ConflictPolicy = .fail, limits: Limits = .init(),
                passphrase: String? = nil, stripRoot: String? = nil) {
        self.conflictPolicy = conflictPolicy
        self.limits = limits
        self.passphrase = passphrase
        self.stripRoot = stripRoot
    }
}

public struct ExtractionProgress: Sendable {
    public let currentEntry: ArchiveEntry
    public let bytesWritten: UInt64
    public let entryBytesWritten: UInt64
    public let entriesDone: UInt64
    public let totalEntries: UInt64

    public var fractionCompleted: Double {
        guard totalEntries != 0 else { return 1 }
        let partial: Double
        if let size = currentEntry.size, size > 0 {
            partial = min(1, Double(entryBytesWritten) / Double(size))
        } else {
            partial = 0
        }
        return min(1, (Double(entriesDone) + partial) / Double(totalEntries))
    }
}

public enum ArchiveError: LocalizedError, Equatable, Sendable {
    case invalidInput, inputOutput, outOfMemory, unknownFormat, corrupt
    case unsupported, unsafePath, limitExceeded, cancelled, conflict, missingEntry, encrypted
    case incorrectPassphrase, unsupportedEncryption, ambiguousResource, invalidProfile, profileMismatch
    case changed, invalidVolumeSet, missingVolume(Int), missingVolumeFile(String), fileAccess(String), core(Int32)

    init(_ status: au_status) {
        switch Int(status) {
        case AU_INVALID: self = .invalidInput
        case AU_IO: self = .inputOutput
        case AU_NOMEM: self = .outOfMemory
        case AU_UNKNOWN_FORMAT: self = .unknownFormat
        case AU_CORRUPT: self = .corrupt
        case AU_UNSUPPORTED: self = .unsupported
        case AU_UNSAFE_PATH: self = .unsafePath
        case AU_LIMIT: self = .limitExceeded
        case AU_CANCELLED: self = .cancelled
        case AU_EXISTS: self = .conflict
        case AU_NOT_FOUND: self = .missingEntry
        case AU_ENCRYPTED: self = .encrypted
        case AU_BAD_PASSPHRASE: self = .incorrectPassphrase
        case AU_UNSUPPORTED_ENCRYPTION: self = .unsupportedEncryption
        case AU_PROFILE_MISMATCH: self = .profileMismatch
        default: self = .core(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidInput: String(localized: "Invalid argument", bundle: .module)
        case .inputOutput: String(localized: "File or storage I/O failed", bundle: .module)
        case .outOfMemory: String(localized: "Out of memory", bundle: .module)
        case .unknownFormat: String(localized: "Archive format could not be identified", bundle: .module)
        case .corrupt: String(localized: "Archive is incomplete, corrupt, or uses an unreadable encoding", bundle: .module)
        case .unsupported: String(localized: "Archive feature or entry type is unsupported", bundle: .module)
        case .unsafePath: String(localized: "Unsafe archive or destination path", bundle: .module)
        case .limitExceeded: String(localized: "Configured archive safety limit exceeded", bundle: .module)
        case .cancelled: String(localized: "Operation cancelled", bundle: .module)
        case .conflict: String(localized: "A destination item already exists", bundle: .module)
        case .ambiguousResource: String(localized: "Several resource entries use the same path.", bundle: .module)
        case .invalidProfile: String(localized: "The format profile contains invalid or unsupported settings.", bundle: .module)
        case .profileMismatch: String(localized: "The file does not match the format profile", bundle: .module)
        case .missingEntry: String(localized: "Archive entry no longer exists", bundle: .module)
        case .encrypted: String(localized: "This archive requires a password", bundle: .module)
        case .incorrectPassphrase: String(localized: "The password is incorrect or the encrypted data is damaged", bundle: .module)
        case .unsupportedEncryption: String(localized: "This archive uses an unsupported encryption method", bundle: .module)
        case .changed: String(localized: "The archive changed. Open it again before extracting.", bundle: .module)
        case .invalidVolumeSet: String(localized: "Select all parts of one ZIP, 7z or RAR archive.", bundle: .module)
        case .missingVolume(let index):
            String(localized: "Archive part \(String(format: "%03d", index)) is missing.", bundle: .module)
        case .missingVolumeFile(let name): String(localized: "Archive volume \(name) is missing.", bundle: .module)
        case .fileAccess(let details): details
        case .core(let code):
            switch Int(code) {
            case AU_OK: String(localized: "Success", bundle: .module)
            case AU_END: String(localized: "End of archive", bundle: .module)
            default:
                if case .core = ArchiveError(code) {
                    String(localized: "Unknown archive error", bundle: .module)
                } else {
                    ArchiveError(code).errorDescription
                }
            }
        }
    }
}

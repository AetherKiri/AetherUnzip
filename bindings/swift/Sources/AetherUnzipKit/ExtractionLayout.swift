import CAetherUnzip
import Foundation

/// How selected archive entries are laid out relative to the destination folder.
public enum ExtractionMode: String, CaseIterable, Sendable {
    case smart, direct, separateFolder, stripTopLevel
}

public struct ExtractionPlacement: Sendable, Equatable {
    /// The suggested name of a new folder. The caller reserves a unique name at extraction time.
    public let folderName: String?
    /// Pass this to `ExtractionOptions.stripRoot` when extracting into the final folder.
    public let stripRoot: String?
}

public struct ExtractionLayout: Sendable {
    public let topLevelCount: Int
    public let commonDirectory: String?
    public let canStripTopLevel: Bool
    public let archiveFolderName: String
    private let needsEnclosingFolder: Bool
    private let files: [String]

    public func placement(for mode: ExtractionMode) -> ExtractionPlacement? {
        switch mode {
        case .smart:
            if let commonDirectory {
                return .init(folderName: commonDirectory, stripRoot: commonDirectory)
            }
            return .init(folderName: needsEnclosingFolder ? archiveFolderName : nil, stripRoot: nil)
        case .direct:
            return .init(folderName: nil, stripRoot: nil)
        case .separateFolder:
            return .init(folderName: archiveFolderName, stripRoot: nil)
        case .stripTopLevel:
            guard canStripTopLevel, let commonDirectory else { return nil }
            return .init(folderName: nil, stripRoot: commonDirectory)
        }
    }

    /// Checks whether outputs in an existing directory would replace another input in a batch.
    /// A separately reserved output folder cannot contain an input.
    public func wouldReplaceInput(_ inputs: [URL], at directory: URL,
                                  placement: ExtractionPlacement) async -> Bool {
        guard placement.folderName == nil, !inputs.isEmpty else { return false }
        let locale = Locale(identifier: "en_US_POSIX")
        func comparable(_ path: String) -> String {
            path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: locale)
        }
        let prefix = comparable(directory.resolvingSymlinksInPath().standardizedFileURL.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parent = prefix.isEmpty ? "" : prefix + "/"
        let relative = Set(inputs.compactMap { url -> String? in
            let path = comparable(url.resolvingSymlinksInPath().standardizedFileURL.path)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard path.hasPrefix(parent) else { return nil }
            return String(path.dropFirst(parent.count))
        })
        guard !relative.isEmpty else { return false }
        return files.contains { file in
            let path = if placement.stripRoot != nil, let slash = file.firstIndex(of: "/") {
                String(file[file.index(after: slash)...])
            } else { file }
            return relative.contains(comparable(path))
        }
    }

    fileprivate init(archive: ArchiveManifest, selected: Set<ArchiveEntry.ID>?, maxDepth: UInt32) throws {
        guard selected?.isEmpty != true else { throw ArchiveError.invalidInput }
        if let last = selected?.max(), last >= UInt64(archive.entries.count) { throw ArchiveError.missingEntry }
        var roots: Set<Data> = []
        var firstRoot: String?
        var looseFile = false
        var hasDescendants = false
        var paths: [String] = []
        for entry in archive.entries where selected?.contains(entry.id) ?? true {
            try Task.checkCancellation()
            let kind: UInt32
            switch entry.kind {
            case .file: kind = UInt32(AU_ENTRY_FILE)
            case .directory: kind = UInt32(AU_ENTRY_DIRECTORY)
            case .unsupported: throw ArchiveError.unsupported
            }
            let normalized: String? = try entry.path.withCString { name in
                var start: UnsafePointer<CChar>?
                var count = 0
                let status = aether_unzip_normalize_entry_path(name, kind, maxDepth, &start, &count)
                if status == AU_END { return nil }
                guard status == AU_OK, let start else { throw ArchiveError(status) }
                let bytes = UnsafeRawBufferPointer(start: start, count: count)
                return String(decoding: bytes, as: UTF8.self)
            }
            guard let normalized else { continue }
            let slash = normalized.firstIndex(of: "/")
            let root = slash.map { String(normalized[..<$0]) } ?? normalized
            roots.insert(Data(root.utf8))
            if firstRoot == nil { firstRoot = root }
            if entry.kind == .file {
                paths.append(normalized)
                if slash == nil { looseFile = true }
            }
            if slash != nil { hasDescendants = true }
        }
        self.topLevelCount = roots.count
        self.commonDirectory = roots.count == 1 && !looseFile ? firstRoot : nil
        self.canStripTopLevel = self.commonDirectory != nil && hasDescendants
        self.needsEnclosingFolder = roots.count > 1 || paths.count > 1
        self.archiveFolderName = Self.folderName(archive)
        self.files = paths
    }

    private static func folderName(_ archive: ArchiveManifest) -> String {
        var name = (archive.displayName as NSString).deletingPathExtension
        if archive.format == .tar, archive.compression != nil, name.lowercased().hasSuffix(".tar") {
            name = (name as NSString).deletingPathExtension
        }
        if name.isEmpty || name.hasPrefix(".") || name.contains(":") || name.contains("\\") {
            return String(localized: "Extracted Archive", bundle: .module)
        }
        return name
    }
}

extension ArchiveService {
    /// Inspects the selected manifest entries with the same path rules used by Core.
    public func extractionLayout(for manifest: ArchiveManifest, selecting ids: Set<ArchiveEntry.ID>? = nil,
                                 limits: ExtractionOptions.Limits = .init()) async throws -> ExtractionLayout {
        try ExtractionLayout(archive: manifest, selected: ids, maxDepth: limits.maxPathDepth)
    }
}

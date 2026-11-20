import AetherUnzipKit
import Foundation
import Observation

struct SavedFolder: Identifiable, Codable {
    let id: UUID
    let name: String
    let bookmark: Data
}

struct BrowserFolder: Sendable {
    let location: WorkspaceAccess
    var components: [String] = []
    var isDocuments = false

    var url: URL { components.reduce(location.url) { $0.appending(path: $1, directoryHint: .isDirectory) } }
    var name: String { components.last ?? rootName }
    var rootName: String { isDocuments ? String(localized: "My Files") : location.url.lastPathComponent }
    var identity: URL { url.standardizedFileURL }
    var canGoUp: Bool { !components.isEmpty }

    func item(_ name: String) -> URL { url.appending(path: name) }

    func child(_ name: String) -> BrowserFolder {
        var child = self
        child.components.append(name)
        return child
    }

    func ancestor(depth: Int) -> BrowserFolder {
        var ancestor = self
        ancestor.components = Array(components.prefix(depth))
        return ancestor
    }

    static var documents: BrowserFolder {
        BrowserFolder(location: WorkspaceAccess(.documentsDirectory), isDocuments: true)
    }
}

@MainActor @Observable
final class FileBrowserModel {
    var folder = BrowserFolder.documents
    private(set) var favorites: [SavedFolder] = []
    private(set) var files: [WorkspaceFile] = []
    private(set) var loading = false
    private(set) var working = false
    private(set) var loadError: String?

    private let service = FileWorkspace()
    private var loadingTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "savedFolders") {
            favorites = (try? JSONDecoder().decode([SavedFolder].self, from: data)) ?? []
        }
    }

    func show(_ folder: BrowserFolder) {
        if self.folder.identity != folder.identity { files = [] }
        self.folder = folder
        reload()
    }

    func reload() {
        loadingTask?.cancel()
        loading = true
        loadError = nil
        let folder = self.folder
        loadingTask = Task {
            do {
                if folder.isDocuments {
                    try await Task.detached(priority: .utility) {
                        _ = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
                    }.value
                }
                let entries = try await service.contents(of: folder.url, access: folder.location)
                guard !Task.isCancelled else { return }
                files = entries
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                files = []
                loadError = error.localizedDescription
                loading = false
            }
        }
    }

    func add(_ url: URL) async throws {
        let access = WorkspaceAccess(url)
        let bookmark = try await Task.detached(priority: .userInitiated) {
            try access.bookmark()
        }.value
        if let index = favorites.firstIndex(where: { $0.bookmark == bookmark }) {
            favorites.remove(at: index)
        }
        favorites.append(SavedFolder(id: UUID(), name: url.lastPathComponent, bookmark: bookmark))
        saveFavorites()
        show(BrowserFolder(location: access))
    }

    func show(_ saved: SavedFolder) async throws {
        let access = try await Task.detached(priority: .userInitiated) {
            try WorkspaceAccess.restore(saved.bookmark)
        }.value
        show(BrowserFolder(location: access))
    }

    func remove(_ saved: SavedFolder) {
        favorites.removeAll { $0.id == saved.id }
        saveFavorites()
    }

    func mutate(_ operation: @escaping @Sendable (FileWorkspace) async throws -> Void) async throws {
        guard !working else { return }
        working = true
        defer {
            working = false
            reload()
        }
        try await operation(service)
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "savedFolders")
        }
    }
}

enum ArchiveNames {
    private static let extensions: Set<String> = [
        "zip", "zip64", "7z", "rar", "tar", "gz", "tgz", "lz4", "zst", "zstd", "xz", "txz",
        "bz2", "tbz", "tbz2", "br", "cab", "iso", "lha", "lzh", "xp3"
    ]

    static func matches(_ name: String) -> Bool {
        let base = name.lowercased()
        let suffix = (base as NSString).pathExtension
        if extensions.contains(suffix) { return true }
        if suffix.count == 3 && suffix.utf8.allSatisfy({ (48...57).contains($0) }) {
            return base.hasSuffix(".7z." + suffix) || base.hasSuffix(".zip." + suffix)
        }
        if suffix.count == 3, ["z", "r"].contains(suffix.first ?? " "),
           suffix.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) { return true }
        return false
    }

    static func correctedName(for archive: ArchiveManifest) -> String? {
        let suffixes: [String]
        switch archive.format {
        case .unknown: return nil
        case .zip: suffixes = ["zip", "zip64"]
        case .sevenZip: suffixes = ["7z"]
        case .rar, .rar5: suffixes = ["rar"]
        case .tar:
            switch archive.compression {
            case nil: suffixes = ["tar"]
            case .gzip: suffixes = ["tar.gz", "tgz"]
            case .lz4: suffixes = ["tar.lz4"]
            case .zstandard: suffixes = ["tar.zst", "tar.zstd"]
            case .xz: suffixes = ["tar.xz", "txz"]
            case .bzip2: suffixes = ["tar.bz2", "tbz", "tbz2"]
            default: return nil
            }
        case .gzip: suffixes = ["gz"]
        case .lz4: suffixes = ["lz4"]
        case .zstandard: suffixes = ["zst", "zstd"]
        case .xz: suffixes = ["xz"]
        case .bzip2: suffixes = ["bz2"]
        case .brotli: suffixes = ["br"]
        case .cab: suffixes = ["cab"]
        case .iso9660: suffixes = ["iso"]
        case .lha: suffixes = ["lha", "lzh"]
        case .xp3: suffixes = ["xp3"]
        }

        let lower = archive.displayName.lowercased()
        guard let preferred = suffixes.first,
              !suffixes.contains(where: { lower.hasSuffix("." + $0) }) else { return nil }
        var stem = (archive.displayName as NSString).deletingPathExtension
        if preferred.hasPrefix("tar."), stem.lowercased().hasSuffix(".tar") {
            stem = (stem as NSString).deletingPathExtension
        }
        // A numbered RAR suffix would make the regular open flow expect multiple volumes.
        if preferred == "rar", stem.range(of: #"\.part[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return stem + "." + preferred
    }

    static func extractionFolder(for file: String) -> String {
        var name = file
        let lower = name.lowercased()
        if lower.hasSuffix(".001") { name = (name as NSString).deletingPathExtension }
        name = (name as NSString).deletingPathExtension
        if name.lowercased().hasSuffix(".tar") { name = (name as NSString).deletingPathExtension }
        if let range = name.range(of: #"\.part[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") { return String(localized: "Extracted Archive") }
        return name
    }
}

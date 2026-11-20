import AetherUnzipKit
import Foundation

struct ExtractionItem: Identifiable {
    let id = UUID()
    let archive: ArchiveManifest
    let selection: Set<ArchiveEntry.ID>?
    let access: [WorkspaceAccess]
    let layout: ExtractionLayout

    var needsPassword: Bool {
        archive.capabilities.contains(.encryption) && !archive.hasOpeningPassphrase && archive.entries.contains {
            $0.kind == .file && $0.isEncrypted && (selection?.contains($0.id) ?? true)
        }
    }
}

struct ExtractionIssue: Identifiable {
    let id = UUID()
    let name: String
    let reason: String
    let needsPassword: Bool
}

struct ExtractionDraft: Identifiable {
    enum Source {
        case archive(ArchiveManifest, Set<ArchiveEntry.ID>?)
        case batch([[URL]])
    }

    let id = UUID()
    let source: Source
    let origin: BrowserFolder?
    let destination: BrowserFolder?
    let lastDestination: BrowserFolder?
    let mode: ExtractionMode
    let conflict: ExtractionOptions.ConflictPolicy
    var access: [WorkspaceAccess] = []
    var choosePassword = false

    var title: String {
        switch source {
        case .archive(let archive, _): archive.displayName
        case .batch(let groups): String(localized: "\(groups.count) archives")
        }
    }

    var isBatch: Bool {
        if case .batch = source { return true }
        return false
    }

    var inputURLs: [URL] {
        switch source {
        case .archive(let archive, _): archive.sourceURLs
        case .batch(let groups): groups.flatMap { $0 }
        }
    }
}

struct ExtractionRun {
    let items: [ExtractionItem]
    let issues: [ExtractionIssue]
    let inputURLs: [URL]
    let destination: BrowserFolder
    let mode: ExtractionMode
    let conflict: ExtractionOptions.ConflictPolicy
    let isBatch: Bool
    let choosePassword: Bool
    let usePasswordLibrary: Bool
}

extension ExtractionMode {
    var title: String {
        switch self {
        case .smart: String(localized: "Smart Extraction")
        case .direct: String(localized: "Extract Directly")
        case .separateFolder: String(localized: "Separate Folder")
        case .stripTopLevel: String(localized: "Remove Top Folder")
        }
    }

    var detail: String {
        switch self {
        case .smart: String(localized: "Keep a shared top folder or group loose items into one folder. Single files go directly into the destination.")
        case .direct: String(localized: "Write directly into the destination, preserving archive paths.")
        case .separateFolder: String(localized: "Create a folder named after each archive and preserve its contents inside.")
        case .stripTopLevel: String(localized: "Place the contents of the shared top folder directly in the destination.")
        }
    }
}

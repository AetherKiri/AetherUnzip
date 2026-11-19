import AetherUnzipKit
import Foundation

struct ArchiveNode: Identifiable, Sendable {
    let id: String
    let name: String
    let entry: ArchiveEntry?
    let children: [ArchiveNode]?

    static func build(_ entries: [ArchiveEntry]) -> [ArchiveNode] {
        let root = Branch(name: "", path: "")
        for entry in entries {
            var components = entry.path.split(separator: "/").map(String.init)
            while components.first == "." { components.removeFirst() }
            if components.isEmpty, isRootMarker(entry) { continue }
            if components.isEmpty { components = [entry.path] }
            // Unsafe paths remain visible as single entries, without building deep UI trees.
            if components.count > 32 || entry.path.hasPrefix("/") ||
                components.contains("..") || components.contains(".") {
                components = [entry.path]
            }
            var branch = root
            for component in components.dropLast() { branch = branch.directory(component) }
            let name = components[components.count - 1]
            if entry.kind == .directory && branch.directory(name).entry == nil {
                branch.directory(name).entry = entry
            } else {
                branch.leaves.append(ArchiveNode(id: "entry:\(entry.id)", name: name,
                                                 entry: entry, children: nil))
            }
        }
        return root.nodes()
    }

    static func isRootMarker(_ entry: ArchiveEntry) -> Bool {
        guard entry.kind == .directory, entry.path.first == "." else { return false }
        return entry.path.split(separator: "/").allSatisfy { $0 == "." }
    }

    private final class Branch {
        let name: String
        let path: String
        var entry: ArchiveEntry?
        var directories: [String: Branch] = [:]
        var leaves: [ArchiveNode] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func directory(_ name: String) -> Branch {
            if let child = directories[name] { return child }
            let child = Branch(name: name, path: path + "/" + name)
            directories[name] = child
            return child
        }

        func nodes() -> [ArchiveNode] {
            let folders = directories.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.map { child in
                ArchiveNode(id: "directory:" + child.path, name: child.name, entry: child.entry,
                            children: child.nodes())
            }
            return folders + leaves.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
    }
}

#if os(iOS)
struct ArchiveBrowsing {
    var folders: [String] = []
    var selecting = false
    var query = ""
}
#endif

struct ArchiveBrowserIndex: Sendable {
    let root: [ArchiveNode]
    let itemCount: Int
    private var directories: [String: ArchiveNode] = [:]
    private(set) var files: [ArchiveNode] = []

    init(_ entries: [ArchiveEntry]) {
        root = ArchiveNode.build(entries)
        itemCount = entries.reduce(into: 0) { count, entry in
            if !ArchiveNode.isRootMarker(entry) { count += 1 }
        }
        for node in root { index(node) }
    }

    subscript(folder id: String) -> ArchiveNode? { directories[id] }

    private mutating func index(_ node: ArchiveNode) {
        if let children = node.children {
            directories[node.id] = node
            for child in children { index(child) }
        } else {
            files.append(node)
        }
    }
}

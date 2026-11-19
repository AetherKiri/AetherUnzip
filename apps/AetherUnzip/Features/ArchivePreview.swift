import AetherUnzipKit
import SwiftUI

struct ArchivePreview: View {
    let archive: ArchiveManifest
    @Binding var selection: Set<ArchiveEntry.ID>
    let busy: Bool
    let limits: ExtractionOptions.Limits
    let close: () -> Void
    let openNested: (ArchiveEntry) -> Void
    let extract: (Set<ArchiveEntry.ID>?) -> Void
    @State private var tree: [ArchiveNode] = []
    @State private var preview: FilePreview.Request?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: archive.isStream ? "doc.zipper" : "archivebox")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(archive.displayName)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    if archive.isNested { Label("Parent Archive", systemImage: "arrow.uturn.backward") }
                    else { Label("Close Preview", systemImage: "xmark") }
                }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier(archive.isNested ? "parent-archive" : "close-archive")
            }
            .padding()
            Divider()
            if archive.entries.isEmpty {
                ContentUnavailableView("Empty Archive", systemImage: "folder")
            } else {
                List {
                    OutlineGroup(tree, children: \.children) { node in
                        entryRow(node)
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("archive-entries")
            }
            if !archive.hasOpeningPassphrase, archive.entries.contains(where: \.isEncrypted) {
                Label(archive.capabilities.contains(.encryption)
                      ? "A password is required to extract locked entries."
                      : "The encryption used by these entries is unsupported.",
                      systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if archive.capabilities.contains(.extract) {
                Divider()
                ViewThatFits {
                    HStack { actions }
                    VStack(alignment: .trailing) { actions }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding()
            }
        }
        .navigationTitle("Archive Preview")
        .task(id: archive.entries) { tree = ArchiveNode.build(archive.entries) }
        .sheet(item: $preview) { request in
            FilePreview(archive: archive, request: request, limits: limits)
        }
    }

    @ViewBuilder private var actions: some View {
        if !selection.isEmpty {
            Button("Clear Selection") { selection.removeAll() }
        }
        Button("Extract Selected (\(selection.count))") { extract(selection) }
            .disabled(selection.isEmpty || busy)
            .accessibilityIdentifier("extract-selected")
        Button("Extract All") { extract(nil) }
            .buttonStyle(.borderedProminent)
            .disabled(archive.entries.isEmpty || busy || archive.entries.contains {
                !$0.isExtractable(supporting: archive.capabilities)
            })
            .accessibilityIdentifier("extract-all")
    }

    private func entryRow(_ node: ArchiveNode) -> some View {
        HStack(spacing: 8) {
            if let entry = node.entry, entry.isExtractable(supporting: archive.capabilities),
               entry.kind == .file {
                Button {
                    if selection.contains(entry.id) { selection.remove(entry.id) }
                    else { selection.insert(entry.id) }
                } label: {
                    Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(entry.id) ? Color.accentColor : .secondary)
                        .frame(minWidth: 24, minHeight: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Select \(node.name)")
                .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
            }
            Label(node.name, systemImage: icon(node))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let entry = node.entry, entry.kind == .file {
                Text(entry.size.map(formattedBytes) ?? "Unknown size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if archive.capabilities.contains(.read),
                   let request = FilePreview.Request(entry: entry, name: node.name,
                                                     capabilities: archive.capabilities) {
                    Button {
                        preview = request
                    } label: {
                        Image(systemName: "eye")
                            .frame(minWidth: 24, minHeight: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Preview \(node.name)")
                    .help("Preview \(node.name)")
                }
                if mayOpenArchive(entry), Self.archiveExtensions.contains(
                    URL(fileURLWithPath: node.name).pathExtension.lowercased()
                ) {
                    Button { openNested(entry) } label: {
                        Image(systemName: "archivebox")
                            .frame(minWidth: 24, minHeight: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open \(node.name) as Archive")
                    .accessibilityIdentifier("open-nested-\(entry.id)")
                    .help("Open as Archive")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(node.entry.map { "archive-entry-\($0.id)" } ?? node.id)
        .contextMenu {
            if let entry = node.entry, entry.kind == .file, mayOpenArchive(entry) {
                Button("Open as Archive") { openNested(entry) }
            }
        }
    }

    private static let archiveExtensions: Set<String> = [
        "zip", "zip64", "7z", "rar", "tar", "gz", "tgz", "lz4", "zst", "xz", "txz",
        "bz2", "tbz", "tbz2", "br", "cab", "iso", "lha", "lzh", "xp3"
    ]

    private func mayOpenArchive(_ entry: ArchiveEntry) -> Bool {
        archive.capabilities.contains(.read) && entry.isExtractable(supporting: archive.capabilities)
    }

    private func icon(_ node: ArchiveNode) -> String {
        if node.children != nil { return "folder" }
        if node.entry?.isEncrypted == true { return "lock.doc" }
        if node.entry?.kind == .unsupported { return "exclamationmark.triangle" }
        return "doc"
    }

    private var summary: String {
        let format = if let filter = archive.compression, filter != archive.format {
            "\(archive.format) · \(filter)"
        } else if archive.isStream {
            "\(archive.format) stream"
        } else {
            archive.format.description
        }
        let parts = archive.isNested || archive.sourceURLs.count == 1
            ? "" : " · \(archive.sourceURLs.count) parts"
        let count = archive.entries.count
        let items = count == 1 ? "1 item" : "\(count) items"
        return "\(format) · \(formattedBytes(archive.compressedSize)) · \(items)\(parts)"
    }
}

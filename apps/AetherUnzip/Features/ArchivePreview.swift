import AetherUnzipKit
import SwiftUI

struct ArchivePreview: View {
    let archive: ArchiveManifest
    @Binding var selection: Set<ArchiveEntry.ID>
    #if os(iOS)
    @Binding var browsing: ArchiveBrowsing
    #endif
    let busy: Bool
    let limits: ExtractionOptions.Limits
    let close: () -> Void
    let openNested: (ArchiveEntry) -> Void
    let extract: (Set<ArchiveEntry.ID>?) -> Void
    let extractWithPassword: (Set<ArchiveEntry.ID>?) -> Void
    let nearbyDestination: String?
    let extractNearby: (Set<ArchiveEntry.ID>?, ArchiveFileAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var browserIndex: ArchiveBrowserIndex?
    #if os(macOS)
    @State private var search = ""
    #else
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif
    @State private var preview: FilePreview.Request?
    @State private var extractAfterPreview: ArchiveEntry.ID?

    var body: some View {
        archiveBrowser.sheet(item: $preview, onDismiss: finishPreview) { request in
            FilePreview(archive: archive, request: request, limits: limits) {
                extractAfterPreview = request.id
                preview = nil
            }
        }
    }

    private var archiveBrowser: some View {
        #if os(iOS)
        NavigationStack(path: $browsing.folders) {
            mobilePage(folder: nil)
                .navigationDestination(for: String.self) { id in
                    if let folder = browserIndex?[folder: id] {
                        mobilePage(folder: folder)
                    } else {
                        ProgressView("Loading files…")
                    }
                }
        }
        .task(id: archive.entries) { await prepareIndex() }
        #else
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                WorkspaceHeading(title: archive.displayName, symbol: "doc.zipper", tint: .teal, detail: summary)
                closeButton
            }
            .modifier(WorkspaceHeaderLayout())
            if browserIndex?.itemCount == 0 {
                ContentUnavailableView("Empty Archive", systemImage: "folder")
            } else if let browserIndex {
                let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = query.isEmpty ? [] : searchResults(query, in: browserIndex)
                List {
                    if query.isEmpty {
                        OutlineGroup(browserIndex.root, children: \.children) { node in
                            entryRow(node)
                        }
                    } else if matches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ForEach(matches) { node in entryRow(node, showingPath: true) }
                    }
                }
                .modifier(WorkspaceListSurface())
                .accessibilityIdentifier("archive-entries")
            } else {
                ProgressView("Loading files…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .modifier(WorkspaceCanvas())
        .navigationTitle("Archive Preview")
        .searchable(text: $search, prompt: "Find files in archive")
        .task(id: archive.entries) { await prepareIndex() }
        #endif
    }

    private func finishPreview() {
        guard let id = extractAfterPreview else { return }
        extractAfterPreview = nil
        extract([id])
    }

    private func prepareIndex() async {
        let entries = archive.entries
        let index = await Task.detached(priority: .userInitiated) { ArchiveBrowserIndex(entries) }.value
        if !Task.isCancelled { browserIndex = index }
    }

    private func searchResults(_ query: String, in index: ArchiveBrowserIndex) -> [ArchiveNode] {
        index.files.filter { $0.entry?.path.localizedStandardContains(query) == true }
    }

    private func toggleSelection(_ id: ArchiveEntry.ID) {
        withAnimation(reduceMotion ? nil : WorkspaceMotion.feedback) {
            if selection.contains(id) { selection.remove(id) }
            else { selection.insert(id) }
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Label(archive.isNested ? "Parent Archive" : "Close Archive",
                  systemImage: archive.isNested ? "chevron.left" : "xmark")
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 26)
        }
        .modifier(WorkspaceButton())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(archive.isNested ? "parent-archive" : "close-archive")
    }

    #if os(iOS)
    private func mobilePage(folder: ArchiveNode?) -> some View {
        let query = browsing.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 0) {
            mobileHeader(folder)
            if let browserIndex {
                let nodes = query.isEmpty
                    ? (folder?.children ?? browserIndex.root)
                    : searchResults(query, in: browserIndex)
                if !query.isEmpty && nodes.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if nodes.isEmpty {
                    ContentUnavailableView(folder == nil ? "Empty Archive" : "This Folder Is Empty",
                                           systemImage: "folder")
                } else {
                    mobileList(nodes, searching: !query.isEmpty)
                }
            } else {
                ProgressView("Loading files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(WorkspaceCanvas())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func mobileHeader(_ folder: ArchiveNode?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                WorkspaceHeading(title: folder?.name ?? archive.displayName,
                                 symbol: folder == nil ? "doc.zipper" : "folder.fill",
                                 tint: folder == nil ? WorkspacePalette.archive : .accentColor,
                                 detail: folder == nil ? summary : archive.displayName,
                                 singleLine: true)
                if folder == nil {
                    closeButton
                } else {
                    Button { _ = browsing.folders.popLast() } label: {
                        Label("Parent Folder", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .frame(width: 26, height: 26)
                    }
                    .modifier(WorkspaceButton())
                    .accessibilityIdentifier("archive-folder-up")
                }
            }
            WorkspaceSearchField(prompt: "Find files in archive", text: $browsing.query, focus: $searchFocused,
                                 identifier: "archive-search", clearIdentifier: "clear-archive-search")
            mobileExtractionBar
            if !archive.hasOpeningPassphrase, archive.entries.contains(where: \.isEncrypted) {
                Label(archive.capabilities.contains(.encryption)
                      ? "Contains locked files" : "Contains unsupported encrypted files", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(WorkspaceHeaderLayout())
    }

    private func mobileList(_ nodes: [ArchiveNode], searching: Bool) -> some View {
        List(nodes) { node in
            mobileRow(node, searching: searching)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
        .modifier(WorkspaceListSurface())
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("archive-entries")
    }

    @ViewBuilder private func mobileRow(_ node: ArchiveNode, searching: Bool) -> some View {
        if node.children != nil {
            NavigationLink(value: node.id) {
                mobileLabel(node, searching: false)
            }
            .accessibilityIdentifier(node.id)
        } else if let entry = node.entry {
            if browsing.selecting, isSelectable(entry) {
                Button {
                    toggleSelection(entry.id)
                } label: {
                    HStack {
                        WorkspaceSelectionMark(selected: selection.contains(entry.id), unselectedTint: .accentColor)
                            .accessibilityHidden(true)
                        mobileLabel(node, searching: searching)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(selection.contains(entry.id) ? WorkspacePalette.accent.opacity(0.15) : nil)
                .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
                .accessibilityIdentifier("archive-entry-\(entry.id)")
            } else if browsing.selecting {
                mobileLabel(node, searching: searching)
            } else {
                mobileFileRow(node, entry: entry, searching: searching)
                    .accessibilityIdentifier("archive-entry-\(entry.id)")
            }
        }
    }

    private func mobileFileRow(_ node: ArchiveNode, entry: ArchiveEntry, searching: Bool) -> some View {
        let canOpen = entry.kind == .file && mayOpenArchive(entry)
        let isArchive = canOpen && ArchiveNames.matches(node.name)
        return HStack(spacing: 4) {
            if isArchive {
                Button { openNested(entry) } label: {
                    mobileLabel(node, searching: searching)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(node.name) as Archive")
                .accessibilityIdentifier("open-nested-\(entry.id)")
            } else if canOpen, let request = FilePreview.Request(entry: entry, name: node.name,
                                                                 capabilities: archive.capabilities) {
                Button { preview = request } label: {
                    mobileLabel(node, searching: searching)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(node.name)")
                .accessibilityValue(fileDetails(node, searching: searching))
            } else {
                mobileLabel(node, searching: searching)
            }
        }
        .contextMenu {
            if canOpen && !isArchive {
                Button("Open as Archive", systemImage: "archivebox") { openNested(entry) }
            }
            if canOpen && archive.capabilities.contains(.extract) {
                Button("Extract This File…", systemImage: "arrow.down.to.line") { extract([entry.id]) }
                    .disabled(busy)
            }
        }
    }

    private func mobileLabel(_ node: ArchiveNode, searching: Bool) -> some View {
        HStack(spacing: 10) {
            WorkspaceGlyph(symbol: icon(node), tint: nodeTint(node))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.body.weight(node.children == nil ? .regular : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                let details = fileDetails(node, searching: searching)
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func fileDetails(_ node: ArchiveNode, searching: Bool) -> String {
        if let children = node.children {
            return String(localized: "\(children.count) items")
        }
        guard let entry = node.entry else { return "" }
        var details: [String] = []
        if searching {
            details.append(entry.path.lastIndex(of: "/").map { String(entry.path[..<$0]) } ?? String(localized: "Archive root"))
        }
        if entry.kind == .file { details.append(entry.size.map(formattedBytes) ?? String(localized: "Unknown size")) }
        if !entry.isExtractable(supporting: archive.capabilities) { details.append(String(localized: "Extraction unavailable")) }
        return details.joined(separator: " · ")
    }

    private func isSelectable(_ entry: ArchiveEntry) -> Bool {
        entry.kind == .file && entry.isExtractable(supporting: archive.capabilities)
    }

    @ViewBuilder private var mobileExtractionBar: some View {
        if archive.capabilities.contains(.extract), (browserIndex?.itemCount ?? 0) > 0 {
            let selected = !selection.isEmpty
            let blocked = archive.entries.contains { !$0.isExtractable(supporting: archive.capabilities) }
            let actionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 6))
            VStack(alignment: .leading, spacing: 8) {
                if blocked && !selected {
                    Text("Some items can’t be extracted. Select the files you want to keep.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                actionLayout {
                    Button {
                        searchFocused = false
                        extract(selected ? selection : nil)
                    } label: {
                        Label {
                            Text(selected ? "Extract \(selection.count)" : "Extract All")
                                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selection.count)))
                        } icon: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    }
                    .modifier(WorkspaceButton(prominent: true))
                    .disabled(busy || (!selected && blocked))
                    .accessibilityLabel(selected ? "Extract Selected (\(selection.count))" : "Extract All")
                    .accessibilityIdentifier(selected ? "extract-selected" : "extract-all")
                    nearbyMenu(selected ? selection : nil)
                        .disabled(busy || (!selected && blocked))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    Button {
                        withAnimation(reduceMotion ? nil : WorkspaceMotion.feedback) {
                            browsing.selecting.toggle()
                            if !browsing.selecting { selection.removeAll() }
                        }
                    } label: {
                        Text(browsing.selecting ? "Done" : "Select")
                            .contentTransition(reduceMotion ? .identity : .opacity)
                    }
                    .font(.subheadline.weight(.semibold))
                    .modifier(WorkspaceButton())
                    .foregroundStyle(Color.primary)
                    .disabled(!browsing.selecting && !archive.entries.contains(where: isSelectable))
                    .accessibilityIdentifier("select-entries")
                }
                if !blocked || selected { passwordAction(selected ? selection : nil) }
            }
        }
    }
    #else
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
        nearbyMenu(selection.isEmpty ? nil : selection)
            .disabled(busy || (selection.isEmpty && archive.entries.contains {
                !$0.isExtractable(supporting: archive.capabilities)
            }))
        if !selection.isEmpty || archive.entries.allSatisfy({ $0.isExtractable(supporting: archive.capabilities) }) {
            passwordAction(selection.isEmpty ? nil : selection)
        }
    }

    private func entryRow(_ node: ArchiveNode, showingPath: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let entry = node.entry, entry.isExtractable(supporting: archive.capabilities),
               entry.kind == .file {
                Button {
                    toggleSelection(entry.id)
                } label: {
                    WorkspaceSelectionMark(selected: selection.contains(entry.id))
                        .frame(minWidth: 24, minHeight: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Select \(node.name)")
                .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
            }
            WorkspaceGlyph(symbol: icon(node), tint: nodeTint(node), size: 26)
            Text(showingPath ? node.entry?.path ?? node.name : node.name).lineLimit(1)
            Spacer(minLength: 8)
            if let entry = node.entry, entry.kind == .file {
                Text(entry.size.map(formattedBytes) ?? String(localized: "Unknown size"))
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
                if mayOpenArchive(entry), ArchiveNames.matches(node.name) {
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
                if archive.capabilities.contains(.extract) {
                    Button("Extract This File…", systemImage: "arrow.down.to.line") { extract([entry.id]) }
                        .disabled(busy)
                }
            }
        }
    }
    #endif

    @ViewBuilder private func nearbyMenu(_ selection: Set<ArchiveEntry.ID>?) -> some View {
        if let nearbyDestination {
            #if os(iOS)
            NearbyDestinationButton(folder: nearbyDestination) { action in extractNearby(selection, action) }
            #else
            Menu {
                Button("Smart Extract Here…", systemImage: "wand.and.sparkles") { extractNearby(selection, .extractSmart) }
                Button("Extract Here", systemImage: "arrow.down.to.line") { extractNearby(selection, .extractHere) }
                Button("Extract to New Folder", systemImage: "folder.badge.plus") {
                    extractNearby(selection, .extractToNewFolder)
                }
                Divider()
                Text(nearbyDestination)
            } label: {
                Label("Other Destinations", systemImage: "folder")
            }
            .accessibilityIdentifier("archive-extract-destinations")
            #endif
        }
    }

    @ViewBuilder private func passwordAction(_ selection: Set<ArchiveEntry.ID>?) -> some View {
        if archive.capabilities.contains(.encryption), archive.entries.contains(where: {
            $0.kind == .file && $0.isEncrypted && (selection?.contains($0.id) ?? true)
        }) {
            Button {
                extractWithPassword(selection)
            } label: {
                Label("Extract with Password…", systemImage: "key")
                    .font(.subheadline)
            }
            .disabled(busy)
            .accessibilityIdentifier("extract-with-password")
        }
    }

    private func mayOpenArchive(_ entry: ArchiveEntry) -> Bool {
        archive.capabilities.contains(.read) && entry.isExtractable(supporting: archive.capabilities)
    }

    private func icon(_ node: ArchiveNode) -> String {
        if node.children != nil { return "folder.fill" }
        if node.entry?.isEncrypted == true { return "lock.doc" }
        if node.entry?.kind == .unsupported { return "exclamationmark.triangle" }
        return ArchiveNames.matches(node.name) ? "doc.zipper" : "doc.text"
    }

    private func nodeTint(_ node: ArchiveNode) -> Color {
        if node.children != nil { return .accentColor }
        if node.entry?.kind == .unsupported || node.entry?.isEncrypted == true { return .orange }
        return ArchiveNames.matches(node.name) ? .teal : .secondary
    }

    private var summary: String {
        let format = if let filter = archive.compression, filter != archive.format {
            "\(archive.format) · \(filter)"
        } else if archive.isStream {
            String(localized: "\(archive.format.description) stream")
        } else {
            archive.format.description
        }
        var fields = [format, formattedBytes(archive.compressedSize)]
        if let index = browserIndex { fields.append(String(localized: "\(index.itemCount) items")) }
        if !archive.isNested && archive.sourceURLs.count > 1 {
            fields.append(String(localized: "\(archive.sourceURLs.count) parts"))
        }
        return fields.joined(separator: " · ")
    }
}

#if os(iOS)
private struct NearbyDestinationButton: View {
    let folder: String
    let extract: (ArchiveFileAction) -> Void
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            Label("Destination", systemImage: "folder")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .modifier(WorkspaceButton())
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("archive-extract-destinations")
        .popover(isPresented: $choosing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Extraction Destination").font(.headline).accessibilityAddTraits(.isHeader)
                Text(folder).font(.subheadline).foregroundStyle(.secondary)
                Divider().padding(.top, 6)
                destination("Smart Extract Here…", symbol: "wand.and.sparkles", action: .extractSmart)
                destination("Extract Here", symbol: "arrow.down.to.line", action: .extractHere)
                destination("Extract to New Folder", symbol: "folder.badge.plus", action: .extractToNewFolder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 230)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func destination(_ title: LocalizedStringKey, symbol: String, action: ArchiveFileAction) -> some View {
        Button {
            choosing = false
            extract(action)
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(WorkspaceButton())
    }
}
#endif

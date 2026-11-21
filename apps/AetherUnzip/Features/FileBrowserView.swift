import AetherUnzipKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum ArchiveFileAction {
    case browse, extractSmart, extractHere, extractToNewFolder
}

struct FileBrowserView: View {
    @Bindable var model: FileBrowserModel
    let limits: ExtractionOptions.Limits
    let openPicker: () -> Void
    let openProfile: () -> Void
    let addLocation: () -> Void
    let openArchive: ([URL], BrowserFolder, ArchiveFileAction) -> Void
    let extractSelected: ([URL], BrowserFolder) -> Void
    let showError: (String) -> Void

    private enum Sort: String, CaseIterable {
        case name = "Name", modified = "Date Modified", kind = "Kind", size = "Size"

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .modified: String(localized: "Date Modified")
            case .kind: String(localized: "Kind")
            case .size: String(localized: "Size")
            }
        }

        var shortTitle: String { self == .modified ? String(localized: "Date") : title }
        var defaultsToAscending: Bool { self == .name || self == .kind }

        var symbol: String {
            switch self {
            case .name: "textformat"
            case .modified: "calendar"
            case .kind: "square.grid.2x2"
            case .size: "internaldrive"
            }
        }

        func orderTitle(ascending: Bool) -> String {
            switch self {
            case .name, .kind:
                ascending ? String(localized: "A to Z") : String(localized: "Z to A")
            case .modified:
                ascending ? String(localized: "Oldest First") : String(localized: "Newest First")
            case .size:
                ascending ? String(localized: "Smallest First") : String(localized: "Largest First")
            }
        }
    }

    private enum RenameTarget: Identifiable, Sendable {
        case newFolder, item(String)

        var id: String {
            switch self {
            case .newFolder: "new"
            case .item(let name): name
            }
        }
        var title: String {
            switch self {
            case .newFolder: String(localized: "New Folder")
            case .item: String(localized: "Rename")
            }
        }
        var initial: String {
            switch self {
            case .newFolder: ""
            case .item(let name): name
            }
        }
        var action: LocalizedStringKey {
            switch self {
            case .newFolder: "Create"
            case .item: "Rename"
            }
        }
    }

    private struct TransferRequest {
        let names: [String]
        let folder: BrowserFolder
        let operation: FileWorkspace.Transfer
    }

    @AppStorage("fileBrowserSort") private var sort: Sort = .name
    @AppStorage("fileBrowserReverseSort") private var reverseSort = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSort = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingFileActions = false
    #endif
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var preview: URL?
    @State private var details: WorkspaceFile?
    @State private var rename: RenameTarget?
    @State private var recognition: ArchiveRecognitionRequest?
    @State private var recognizedFileToOpen: (URL, BrowserFolder)?
    @State private var creatingFile = false
    @State private var createdFile: WorkspaceTextFile?
    @State private var editor: WorkspaceTextRequest?
    @State private var deletion: [String] = []
    @State private var showDelete = false
    @State private var transfer: TransferRequest?
    @State private var showDestination = false

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            if model.loading && model.files.isEmpty {
                ProgressView("Reading folder…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("Can’t Open Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: model.reload)
                    Button("My Files") { model.show(.documents) }
                }
            } else {
                fileList
            }
        }
        .modifier(WorkspaceCanvas())
        #if os(iOS)
        .toolbar(horizontalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
        #endif
        .task {
            if !model.loading { model.reload() }
        }
        .onChange(of: model.folder.identity) {
            clearSelection()
            query = ""
            searchFocused = false
        }
        .onChange(of: model.files.map(\.id)) {
            selection.formIntersection(Set(model.files.map(\.id)))
        }
        .quickLookPreview($preview)
        .sheet(item: $details) { file in
            VStack(alignment: .leading, spacing: 16) {
                Label(file.name, systemImage: icon(file))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Divider()
                LabeledContent("Location", value: model.folder.name)
                if let size = file.size { LabeledContent("Size", value: formattedBytes(size)) }
                if let modified = file.modified {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Spacer()
                    Button("Done") { details = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(minWidth: 300)
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
        .sheet(item: $rename) { target in
            let folder = model.folder
            FileNameSheet(title: target.title, action: target.action, initial: target.initial,
                          location: folder.name) { name in
                try await applyName(name, to: target, in: folder)
                rename = nil
            }
        }
        .sheet(item: $recognition, onDismiss: {
            guard let (url, folder) = recognizedFileToOpen else { return }
            recognizedFileToOpen = nil
            openArchive([url], folder, .browse)
        }) { request in
            ArchiveRecognitionSheet(request: request, limits: limits) { url, renamed in
                if renamed { model.reload() }
                recognizedFileToOpen = (url, request.folder)
                recognition = nil
            }
        }
        .sheet(isPresented: $creatingFile, onDismiss: {
            guard let createdFile else { return }
            editor = .created(createdFile)
            self.createdFile = nil
        }) {
            NewWorkspaceTextFileSheet(folder: model.folder) { file in
                createdFile = file
                model.reload()
            }
        }
        .sheet(item: $editor) { request in
            WorkspaceTextEditor(request: request, didSave: model.reload)
        }
        .confirmationDialog(deleteTitle, isPresented: $showDelete, titleVisibility: .visible) {
            Button(deleteAction, role: .destructive, action: deletePending)
            Button("Cancel", role: .cancel) { deletion = [] }
        } message: {
            #if os(macOS)
            Text("The selected items will move to the Trash.")
            #else
            Text("The selected items will be permanently deleted.")
            #endif
        }
        .fileImporter(isPresented: $showDestination, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            guard let pending = transfer else { return }
            transfer = nil
            do {
                guard let url = try result.get().first else { return }
                let target = WorkspaceAccess(url)
                perform { service in
                    try await service.transfer(pending.names.map(pending.folder.item), to: target.url,
                                               operation: pending.operation,
                                               sourceAccess: pending.folder.location, destinationAccess: target)
                }
            } catch { showError(error.localizedDescription) }
        } onCancellation: {
            transfer = nil
        }
    }

    private var browserHeader: some View {
        let searchLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.folder.canGoUp {
                    Button {
                        model.show(model.folder.ancestor(depth: model.folder.components.count - 1))
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 26, height: 26)
                    }
                    .modifier(WorkspaceButton())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Parent Folder")
                    .accessibilityIdentifier("parent-file-folder")
                    .help("Parent Folder")
                }
                locationMenu
                Spacer(minLength: 0)
                if model.working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                #if os(iOS)
                if !selecting {
                    Button(action: openPicker) {
                        Label("Open", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .modifier(WorkspaceButton(prominent: true, liquidGlass: true))
                    .accessibilityLabel("Open Archive")
                    .accessibilityIdentifier("open-archive")
                    .help("Open Archive")
                    .disabled(model.working)
                }
                #endif
                if selecting { fileActions }
            }
            searchLayout {
                WorkspaceSearchField(prompt: "Search this folder", text: $query, focus: $searchFocused,
                                     identifier: "workspace-search", clearIdentifier: "clear-workspace-search")
                if !searchFocused {
                    HStack(spacing: 6) {
                        sortMenu
                        if !selecting { fileActions }
                    }
                }
            }
        }
        .modifier(WorkspaceHeaderLayout())
    }

    private var locationMenu: some View {
        Menu {
            if model.folder.canGoUp {
                Section("Path") {
                    Button(model.folder.rootName) { model.show(model.folder.ancestor(depth: 0)) }
                    ForEach(Array(model.folder.components.dropLast().enumerated()), id: \.offset) { index, name in
                        Button(name) { model.show(model.folder.ancestor(depth: index + 1)) }
                    }
                }
            }
            Section("Locations") {
                if !model.folder.isDocuments {
                    Button("My Files", systemImage: "internaldrive") { model.show(.documents) }
                }
                ForEach(model.favorites) { folder in
                    Button(folder.name, systemImage: "folder") { openLocation(folder) }
                }
                Button("Add Folder Location…", systemImage: "folder.badge.plus", action: addLocation)
                if !model.favorites.isEmpty {
                    Menu("Remove Location", systemImage: "minus.circle") {
                        ForEach(model.favorites) { folder in
                            Button(folder.name, role: .destructive) { model.remove(folder) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                WorkspaceDisplayTitle(title: model.folder.name, compact: model.folder.canGoUp)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.primary)
        .accessibilityLabel(model.folder.name)
        .accessibilityHint("Path and saved locations")
        .accessibilityIdentifier(model.folder.canGoUp ? "file-locations" : "file-path-0")
    }

    private var sortMenu: some View {
        Button { showingSort = true } label: { sortLabel }
            .modifier(WorkspaceButton())
            .accessibilityLabel("Sort By")
            .accessibilityValue(sortValue)
            .accessibilityIdentifier("workspace-sort")
            .popover(isPresented: $showingSort, arrowEdge: .top) {
                sortOptions
                #if os(iOS)
                    .presentationCompactAdaptation(.popover)
                #endif
            }
    }

    private var sortOptions: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Sort By").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { showingSort = false }
                    .modifier(WorkspaceButton())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("workspace-sort-done")
            }
            ForEach(Sort.allCases, id: \.self) { option in
                sortOption(option.title, symbol: option.symbol, selected: sort == option) {
                    if sort != option {
                        sort = option
                        reverseSort = false
                    }
                }
            }
            Divider().padding(.vertical, 3)
            ForEach([true, false], id: \.self) { forward in
                sortOption(sort.orderTitle(ascending: forward), symbol: forward ? "arrow.up" : "arrow.down",
                           selected: forward == ascending) {
                    reverseSort = forward != sort.defaultsToAscending
                }
                .accessibilityIdentifier(forward ? "workspace-sort-ascending" : "workspace-sort-descending")
            }
            Text("Folders first")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minWidth: 225, idealWidth: 250)
    }

    private func sortOption(_ title: String, symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline)
        }
        .modifier(WorkspaceButton())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sortLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                .foregroundStyle(.secondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            Text(sort.shortTitle)
                .foregroundStyle(.primary)
                .contentTransition(reduceMotion ? .identity : .opacity)
        }
        .font(.subheadline.weight(.medium))
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 28)
        .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: sort)
        .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: ascending)
    }

    private var ascending: Bool { sort.defaultsToAscending != reverseSort }
    private var sortValue: String {
        let direction = ascending ? String(localized: "Ascending") : String(localized: "Descending")
        return String(localized: "\(sort.title), \(direction)")
    }

    @ViewBuilder private var fileActions: some View {
        if selecting {
            Button("Done", action: clearSelection)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
                .accessibilityIdentifier("finish-file-selection")
        } else {
            #if os(iOS)
            Button { showingFileActions = true } label: { fileActionsLabel }
                .modifier(WorkspaceButton())
                .accessibilityIdentifier("file-actions")
                .disabled(model.working)
                .confirmationDialog("File Actions", isPresented: $showingFileActions, titleVisibility: .visible) {
                    fileActionOptions
                }
            #else
            Menu { fileActionOptions } label: { fileActionsLabel }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityIdentifier("file-actions")
                .disabled(model.working)
            #endif
        }
    }

    private var fileActionsLabel: some View {
        Label("File Actions", systemImage: "ellipsis")
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var fileActionOptions: some View {
        Button("New Folder", systemImage: "folder.badge.plus") { rename = .newFolder }
            .accessibilityIdentifier("new-file-folder")
        Button("New File", systemImage: "doc.badge.plus") { creatingFile = true }
            .accessibilityIdentifier("new-workspace-file")
        Button("Select Items", systemImage: "checkmark.circle") {
            searchFocused = false
            selecting = true
        }
        .accessibilityIdentifier("select-workspace-files")
        .disabled(model.files.isEmpty)
        Button("Open with Format Profile…", systemImage: "doc.badge.gearshape", action: openProfile)
            .accessibilityIdentifier("open-format-profile")
        Button("Refresh", systemImage: "arrow.clockwise", action: model.reload)
    }

    private var fileList: some View {
        let visible = filteredFiles
        return List {
            if visible.isEmpty {
                Group {
                    if query.isEmpty {
                        ContentUnavailableView {
                            Label("This Folder Is Empty", systemImage: "folder")
                        } actions: {
                            Button("New Folder") { rename = .newFolder }
                                .accessibilityIdentifier("empty-new-folder")
                            Button("New File") { creatingFile = true }
                                .accessibilityIdentifier("empty-new-workspace-file")
                        }
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(visible) { file in
                        fileRow(file)
                    }
                } footer: {
                    Text("\(visible.count) items")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("workspace-item-count")
                }
            }
        }
        .modifier(WorkspaceListSurface())
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .accessibilityIdentifier("workspace-files")
        .refreshable { model.reload() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ZStack {
                if selecting {
                    selectionBar.transition(reduceMotion ? .identity : WorkspaceMotion.bottomInset)
                }
            }
            .animation(reduceMotion ? nil : WorkspaceMotion.layout, value: selecting)
        }
    }

    private func fileRow(_ file: WorkspaceFile) -> some View {
        let isArchive = file.kind == .file && ArchiveNames.matches(file.name)
        let opensDirectory = file.kind == .folder || isArchive
        let selected = selection.contains(file.id)
        let tint: Color = file.kind == .folder ? .accentColor : (isArchive ? .teal : .secondary)
        return Button { activate(file) } label: {
            HStack(spacing: 10) {
                if selecting {
                    WorkspaceSelectionMark(selected: selected)
                        .accessibilityHidden(true)
                }
                WorkspaceGlyph(symbol: icon(file), tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body.weight(opensDirectory ? .medium : .regular))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                    if let details = metadata(file) {
                        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if opensDirectory && !selecting {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 5)
            .frame(minHeight: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(selected ? WorkspacePalette.accent.opacity(0.13) : nil)
        .accessibilityIdentifier("workspace-file-\(file.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { fileMenu(file) }
    }

    @ViewBuilder private func fileMenu(_ file: WorkspaceFile) -> some View {
        if file.kind == .file {
            if ArchiveNames.matches(file.name) {
                Button("Open Archive", systemImage: "archivebox") { open(file, action: .browse) }
                Button("Smart Extract Here…", systemImage: "wand.and.sparkles") { open(file, action: .extractSmart) }
                Button("Extract Here", systemImage: "arrow.down.to.line") { open(file, action: .extractHere) }
                Button("Extract to New Folder", systemImage: "folder.badge.plus") { open(file, action: .extractToNewFolder) }
            } else {
                Button("Preview", systemImage: "eye") { preview = model.folder.item(file.name) }
                Button("Open as Archive", systemImage: "archivebox") { open(file, action: .browse) }
            }
            Button("Identify Archive Format…", systemImage: "doc.text.magnifyingglass") {
                recognition = ArchiveRecognitionRequest(name: file.name, folder: model.folder)
            }
            .disabled(model.working)
            .accessibilityIdentifier("identify-workspace-archive")
            Button("Edit Text", systemImage: "square.and.pencil") { edit(file) }
                .accessibilityIdentifier("edit-workspace-text")
            ShareLink(item: model.folder.item(file.name)) { Label("Share", systemImage: "square.and.arrow.up") }
            Divider()
        }
        Button("Info", systemImage: "info.circle") { details = file }
        Button("Rename", systemImage: "pencil") { rename = .item(file.name) }
            .disabled(model.working)
        Button("Copy to…", systemImage: "document.on.document") { chooseTransfer(.copy, names: [file.name]) }
            .disabled(model.working)
        Button("Move to…", systemImage: "folder") { chooseTransfer(.move, names: [file.name]) }
            .disabled(model.working)
        Divider()
        Button(deleteAction, systemImage: "trash", role: .destructive) { confirmDelete([file.name]) }
            .disabled(model.working)
    }

    private var selectionBar: some View {
        HStack {
            Text("\(selection.count) selected")
                .font(.subheadline.weight(.medium))
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(selection.count)))
                .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: selection.count)
            Spacer()
            Menu("Actions", systemImage: "ellipsis.circle") {
                if selectedArchives {
                    Button("Extract Selected…", systemImage: "arrow.down.to.line") {
                        let folder = model.folder
                        extractSelected(selectedNames.map(folder.item), folder)
                        clearSelection()
                    }
                    .accessibilityIdentifier("extract-workspace-selection")
                    Button(selection.count == 1 ? "Open Archive" : "Open as Volume Set", systemImage: "archivebox") {
                        let folder = model.folder
                        openArchive(selectedNames.map(folder.item), folder, .browse)
                    }
                    .accessibilityIdentifier("open-selected-files")
                }
                Button("Copy to…", systemImage: "document.on.document") { chooseTransfer(.copy, names: selectedNames) }
                Button("Move to…", systemImage: "folder") { chooseTransfer(.move, names: selectedNames) }
                Button(deleteAction, systemImage: "trash", role: .destructive) { confirmDelete(selectedNames) }
            }
            .accessibilityIdentifier("workspace-selection-actions")
            .disabled(selection.isEmpty || model.working)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectedNames: [String] {
        selection.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var selectedArchives: Bool {
        !selection.isEmpty && model.files.filter { selection.contains($0.id) }.allSatisfy {
            $0.kind == .file && ArchiveNames.matches($0.name)
        }
    }

    private var filteredFiles: [WorkspaceFile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.files.filter { trimmed.isEmpty || $0.name.localizedStandardContains(trimmed) }
            .sorted { first, second in
                if (first.kind == .folder) != (second.kind == .folder) { return first.kind == .folder }
                switch sort {
                case .modified:
                    let firstDate = first.modified ?? .distantPast
                    let secondDate = second.modified ?? .distantPast
                    if firstDate != secondDate { return ascending ? firstDate < secondDate : firstDate > secondDate }
                case .size:
                    let firstSize = first.size ?? 0
                    let secondSize = second.size ?? 0
                    if firstSize != secondSize { return ascending ? firstSize < secondSize : firstSize > secondSize }
                case .kind:
                    let firstType = (first.name as NSString).pathExtension.lowercased()
                    let secondType = (second.name as NSString).pathExtension.lowercased()
                    if firstType != secondType { return ascending ? firstType < secondType : firstType > secondType }
                case .name: break
                }
                let comparison = first.name.localizedStandardCompare(second.name)
                if comparison == .orderedSame { return first.name < second.name }
                let namesAscending = sort != .name || ascending
                return comparison == (namesAscending ? .orderedAscending : .orderedDescending)
            }
    }

    private func metadata(_ file: WorkspaceFile) -> String? {
        if file.kind == .folder { return file.modified?.formatted(date: .abbreviated, time: .omitted) }
        var parts: [String] = []
        if file.kind == .other { parts.append(String(localized: "Special item")) }
        if let size = file.size { parts.append(formattedBytes(size)) }
        if let date = file.modified { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func icon(_ file: WorkspaceFile) -> String {
        if file.kind == .folder { return "folder.fill" }
        if file.kind == .other { return "doc.badge.ellipsis" }
        if ArchiveNames.matches(file.name) { return "doc.zipper" }
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true || type?.conforms(to: .text) == true { return "doc.text" }
        return "doc"
    }

    private func activate(_ file: WorkspaceFile) {
        if selecting {
            withAnimation(reduceMotion ? nil : WorkspaceMotion.feedback) {
                if selection.contains(file.id) { selection.remove(file.id) }
                else { selection.insert(file.id) }
            }
        } else if file.kind == .folder {
            model.show(model.folder.child(file.name))
        } else if file.kind == .file {
            if ArchiveNames.matches(file.name) { open(file, action: .browse) }
            else if isKnownText(file) { edit(file) }
            else { preview = model.folder.item(file.name) }
        } else {
            details = file
        }
    }

    private func isKnownText(_ file: WorkspaceFile) -> Bool {
        let suffix = (file.name as NSString).pathExtension.lowercased()
        if let format = WorkspaceTextFormat(rawValue: suffix), format != .custom { return true }
        return UTType(filenameExtension: suffix)?.conforms(to: .plainText) == true
    }

    private func edit(_ file: WorkspaceFile) {
        let folder = model.folder
        editor = .existing(folder.item(file.name), folder.location)
    }

    private func open(_ file: WorkspaceFile, action: ArchiveFileAction) {
        let folder = model.folder
        openArchive([folder.item(file.name)], folder, action)
    }

    private func openLocation(_ folder: SavedFolder) {
        Task {
            do { try await model.show(folder) }
            catch { showError(error.localizedDescription) }
        }
    }

    private func clearSelection() {
        selecting = false
        selection = []
    }

    private func applyName(_ name: String, to target: RenameTarget, in folder: BrowserFolder) async throws {
        try await model.mutate { service in
            switch target {
            case .newFolder: _ = try await service.makeFolder(named: name, in: folder.url, access: folder.location)
            case .item(let original): try await service.rename(folder.item(original), to: name, access: folder.location)
            }
        }
        clearSelection()
    }

    private var deleteAction: LocalizedStringKey {
        #if os(macOS)
        "Move to Trash"
        #else
        "Delete"
        #endif
    }

    private var deleteTitle: String {
        if let name = deletion.first, deletion.count == 1 { return String(localized: "Delete \(name)?") }
        return String(localized: "Delete \(deletion.count) items?")
    }

    private func confirmDelete(_ names: [String]) {
        deletion = names
        showDelete = true
    }

    private func deletePending() {
        let folder = model.folder
        let items = deletion.map(folder.item)
        deletion = []
        perform { service in
            try await service.delete(items, access: folder.location)
        }
    }

    private func chooseTransfer(_ operation: FileWorkspace.Transfer, names: [String]) {
        transfer = TransferRequest(names: names, folder: model.folder, operation: operation)
        showDestination = true
    }

    private func perform(_ operation: @escaping @Sendable (FileWorkspace) async throws -> Void) {
        Task {
            do {
                try await model.mutate(operation)
                clearSelection()
            } catch { showError(error.localizedDescription) }
        }
    }
}

private struct FileNameSheet: View {
    let title: String
    let action: LocalizedStringKey
    let initial: String
    let location: String
    let save: (String) async throws -> Void
    @State private var name: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, action: LocalizedStringKey, initial: String, location: String,
         save: @escaping (String) async throws -> Void) {
        self.title = title
        self.action = action
        self.initial = initial
        self.location = location
        self.save = save
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: title, detail: location, singleLine: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        #endif
                        .onSubmit(commit)
                        .accessibilityIdentifier("workspace-file-name")
                    if !name.isEmpty {
                        Button {
                            name = ""
                            focused = true
                        } label: {
                            Label("Clear Name", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly).foregroundStyle(.secondary)
                        }
                        .modifier(WorkspaceButton())
                        .accessibilityIdentifier("workspace-clear-name")
                    }
                }
                .modifier(WorkspaceInputWell(focused: focused, invalid: message != nil))
                .disabled(saving)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("workspace-name-error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                if saving { ProgressView().controlSize(.small).accessibilityLabel("Saving") }
                Button(action, action: commit)
                    .modifier(WorkspaceButton(prominent: true))
                    .disabled(!canSave)
                    .accessibilityIdentifier("workspace-save-name")
            }
        }
        .padding(24)
        #if os(iOS)
        .frame(maxWidth: 480, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 320)
        #endif
        .onAppear { focused = true }
        .onChange(of: name) { error = nil }
        .interactiveDismissDisabled(saving)
    }

    private var invalidName: String? {
        if name == "." || name == ".." { return String(localized: "Choose a name other than ‘.’ or ‘..’.") }
        if name.contains("/") { return String(localized: "Remove the slash (/) from the name.") }
        if name.utf8.contains(0) { return String(localized: "This name contains a character that isn’t allowed.") }
        return nil
    }

    private var message: String? { invalidName ?? error }

    private var canSave: Bool {
        !saving && name != initial && invalidName == nil &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        guard canSave else { return }
        let submittedName = name
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await save(submittedName)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                self.error = String(localized: "That name is already in use in this folder.")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

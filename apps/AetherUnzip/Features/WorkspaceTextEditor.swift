import AetherUnzipKit
import SwiftUI

enum WorkspaceTextRequest: Identifiable {
    case created(WorkspaceTextFile)
    case existing(URL, WorkspaceAccess)

    var id: URL {
        switch self {
        case .created(let file): file.url
        case .existing(let url, _): url
        }
    }
}

struct WorkspaceTextEditor: View {
    let request: WorkspaceTextRequest
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var file: WorkspaceTextFile?
    @State private var draft: String
    @State private var failure: String?
    @State private var saving = false
    @State private var confirmDiscard = false

    init(request: WorkspaceTextRequest, didSave: @escaping () -> Void) {
        self.request = request
        self.didSave = didSave
        if case .created(let file) = request {
            _file = State(initialValue: file)
            _draft = State(initialValue: file.text)
        } else {
            _draft = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if file != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        if let failure {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("workspace-editor-error")
                            Divider()
                        }
                        TextEditor(text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .focused($focused)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .accessibilityLabel("File Contents")
                            .accessibilityIdentifier("workspace-editor-text")
                            .onAppear {
                                if case .created = request { focused = true }
                            }
                    }
                } else if let failure {
                    ContentUnavailableView("Can’t Edit File", systemImage: "doc.text.magnifyingglass",
                                           description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(request.id.lastPathComponent)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: close)
                        .keyboardShortcut(.cancelAction)
                        .disabled(saving)
                        .accessibilityIdentifier("workspace-editor-done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!dirty || saving)
                        .accessibilityIdentifier("workspace-editor-save")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 380)
        #endif
        .interactiveDismissDisabled(dirty || saving)
        .confirmationDialog("Discard Changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .task {
            guard file == nil, case .existing(let url, let access) = request else { return }
            do {
                let loaded = try await FileWorkspace().readText(at: url, access: access)
                guard !Task.isCancelled else { return }
                draft = loaded.text
                file = loaded
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private var dirty: Bool {
        if let file { return !draft.utf8.elementsEqual(file.text.utf8) }
        return false
    }

    private func close() {
        if dirty {
            confirmDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard let file, dirty, !saving else { return }
        let submitted = draft
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                self.file = try await FileWorkspace().saveText(submitted, for: file)
                didSave()
            } catch { failure = error.localizedDescription }
        }
    }
}

enum WorkspaceTextFormat: String, CaseIterable, Identifiable {
    case txt, md, json, csv, yaml, xml, ini, custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .txt: "Plain Text (.txt)"
        case .md: "Markdown (.md)"
        case .json: "JSON (.json)"
        case .csv: "CSV (.csv)"
        case .yaml: "YAML (.yaml)"
        case .xml: "XML (.xml)"
        case .ini: "INI (.ini)"
        case .custom: "Custom Extension"
        }
    }

    var contents: String {
        switch self {
        case .json: "{}\n"
        case .xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root />\n"
        default: ""
        }
    }
}

struct NewWorkspaceTextFileSheet: View {
    let folder: BrowserFolder
    let created: (WorkspaceTextFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @State private var name = ""
    @State private var format = WorkspaceTextFormat.txt
    @State private var suffix = ""
    @State private var saving = false
    @State private var failure: String?

    private enum Field: Hashable { case name, suffix }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceHeading(title: String(localized: "New File"), detail: folder.name)
                field("Name", text: $name, item: .name, identifier: "workspace-new-file-name")
                HStack(spacing: 8) {
                    Text("Format").font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Picker("Format", selection: $format) {
                        ForEach(WorkspaceTextFormat.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workspace-new-file-format")
                }
                if format == .custom {
                    field("File Extension", text: $suffix, item: .suffix, identifier: "workspace-new-file-extension")
                }
                if let filename {
                    Text(filename)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("File Name: \(filename)"))
                }
                if let message = validation ?? failure {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("workspace-new-file-error")
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    if saving { ProgressView().controlSize(.small) }
                    Button("Create", action: create)
                        .modifier(WorkspaceButton(prominent: true))
                        .disabled(filename == nil)
                        .accessibilityIdentifier("workspace-new-file-create")
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .disabled(saving)
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 420, height: 330)
        #endif
        .interactiveDismissDisabled(saving)
        .onAppear { focus = .name }
        .onChange(of: name) { failure = nil }
        .onChange(of: suffix) { failure = nil }
        .onChange(of: format) { failure = nil }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, item: Field,
                       identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .focused($focus, equals: item)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
                .modifier(WorkspaceInputWell(focused: focus == item))
                .accessibilityIdentifier(identifier)
        }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var customExtension: String {
        let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix(".") ? String(value.dropFirst()) : value
    }

    private var validation: String? {
        if cleanName.hasPrefix(".") || cleanName.contains("/") || cleanName.utf8.contains(0) {
            return String(localized: "Use a file name without slashes or a leading dot.")
        }
        if format == .custom, !suffix.isEmpty, customExtension.split(separator: ".", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || !$0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) {
            return String(localized: "Use letters, numbers, hyphens, or underscores in each extension segment.")
        }
        return nil
    }

    private var filename: String? {
        guard !cleanName.isEmpty, validation == nil else { return nil }
        let extensionName = format == .custom ? customExtension : format.rawValue
        guard !extensionName.isEmpty else { return nil }
        let ending = "." + extensionName
        return cleanName.lowercased().hasSuffix(ending.lowercased()) ? cleanName : cleanName + ending
    }

    private func create() {
        guard let filename, !saving else { return }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                let file = try await FileWorkspace().makeTextFile(named: filename, in: folder.url,
                                                                   contents: format.contents, access: folder.location)
                created(file)
                dismiss()
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                failure = String(localized: "That name is already in use in this folder.")
            } catch { failure = error.localizedDescription }
        }
    }
}

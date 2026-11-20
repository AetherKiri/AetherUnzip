import AetherUnzipKit
import SwiftUI

struct SettingsView: View {
    @Binding var conflict: ExtractionOptions.ConflictPolicy
    @Binding var destination: DestinationPolicy
    let safetyLimits: AppSafetyLimits
    let saveSafetyLimits: (AppSafetyLimits) -> Void

    private enum Page: Hashable, Identifiable {
        case conflict, destination, safety, licenses
        var id: Self { self }
    }

    @State private var page: Page?

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: String(localized: "Settings"))
                .modifier(WorkspaceHeaderLayout())
            preferences
        }
        .modifier(WorkspaceCanvas())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(item: $page) { route in
            switch route {
            case .conflict:
                choicePage("Existing Files", options: ExtractionOptions.ConflictPolicy.allCases,
                           selection: $conflict, title: \.settingsTitle, detail: \.settingsDetail)
            case .destination:
                choicePage("Destination", options: DestinationPolicy.allCases,
                           selection: $destination, title: \.title, detail: \.settingsDetail)
            case .safety:
                SafetyLimitsEditor(limits: safetyLimits, save: saveSafetyLimits)
            case .licenses:
                licenses
            }
        }
    }

    private var preferences: some View {
        List {
            Section("Extraction") {
                setting("Existing Files", symbol: "doc.on.doc", value: conflict.settingsTitle,
                        route: .conflict, identifier: "settings-conflict")
                setting("Destination", symbol: "folder", value: destination.title,
                        route: .destination, identifier: "settings-destination")
            }
            Section("Safety") {
                setting("Safety Limits", symbol: "shield",
                        value: safetyLimits == .defaults ? String(localized: "Default") : String(localized: "Custom"),
                        route: .safety, identifier: "settings-safety")
            }
            Section("About") {
                LabeledContent {
                    Text(appVersion).monospacedDigit()
                } label: {
                    Label("App Version", systemImage: "info.circle")
                }
                LabeledContent {
                    Text(ArchiveService.coreVersion).monospacedDigit()
                } label: {
                    Label("AetherUnzip Core", systemImage: "shippingbox")
                }
                setting("Open-source Licenses", symbol: "doc.text", route: .licenses, identifier: "settings-licenses")
            }
        }
        .modifier(WorkspaceListSurface())
    }

    private func setting(_ title: LocalizedStringKey, symbol: String, value: String? = nil,
                         route: Page, identifier: String) -> some View {
        Button { page = route } label: {
            HStack(spacing: 10) {
                WorkspaceGlyph(symbol: symbol, tint: .accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    if let value { Text(value).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value ?? ""))
        .accessibilityIdentifier(identifier)
    }

    private func choicePage<Option: Hashable>(
        _ heading: LocalizedStringKey, options: [Option], selection: Binding<Option>,
        title: KeyPath<Option, String>, detail: KeyPath<Option, String>
    ) -> some View {
        NavigationStack {
            List(options, id: \.self) { option in
                let selected = option == selection.wrappedValue
                Button {
                    selection.wrappedValue = option
                    page = nil
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option[keyPath: title]).font(.body.weight(.medium))
                            Text(option[keyPath: detail]).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(option[keyPath: title]))
                .accessibilityHint(Text(option[keyPath: detail]))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            .modifier(WorkspaceListSurface())
            .navigationTitle(heading)
            .toolbar { Button("Done") { page = nil }.keyboardShortcut(.cancelAction) }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }

    private var licenses: some View {
        NavigationStack {
            List {
                ForEach(["AetherUnzip", "libarchive", "liblzma", "lz4", "zstd", "brotli"], id: \.self) { name in
                    NavigationLink(name) { LicenseDocument(name: name) }
                }
            }
            .modifier(WorkspaceListSurface())
            .navigationTitle("Open-source Licenses")
            .toolbar { Button("Done") { page = nil }.keyboardShortcut(.cancelAction) }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "—"
    }
}

private extension ExtractionOptions.ConflictPolicy {
    var settingsTitle: String {
        switch self {
        case .fail: String(localized: "Stop on conflict")
        case .skip: String(localized: "Keep existing")
        case .replace: String(localized: "Replace files")
        }
    }

    var settingsDetail: String {
        switch self {
        case .fail: String(localized: "Stop when a file already exists. Files already extracted are kept.")
        case .skip: String(localized: "Keep the existing file and continue extracting the remaining files.")
        case .replace: String(localized: "Replace existing files with files of the same name from the archive.")
        }
    }
}

private extension DestinationPolicy {
    var settingsDetail: String {
        switch self {
        case .choose: String(localized: "Choose where to save files when you tap Extract.")
        case .documents: String(localized: "Save to Extracted Archives in My Files.")
        }
    }
}

struct AppSafetyLimits: Equatable {
    var entryGiB: Int
    var totalGiB: Int
    var entries: Int
    var depth: Int
    var expansion: Int

    static let defaults = Self(entryGiB: 4, totalGiB: 16, entries: 10_000, depth: 32, expansion: 1_000)
}

private struct SafetyLimitsEditor: View {
    private enum Limit: String, CaseIterable {
        case file, total, entries, depth, expansion

        var title: LocalizedStringKey {
            switch self {
            case .file: "Per File"
            case .total: "Total Output"
            case .entries: "Entries"
            case .depth: "Path Depth"
            case .expansion: "Expansion Ratio"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .file: "Maximum size of one extracted file."
            case .total: "Maximum combined size of extracted data."
            case .entries: "Maximum number of archive entries."
            case .depth: "Maximum number of components in an extracted path."
            case .expansion: "Maximum ratio of extracted to compressed data."
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .file, .depth: 1...64
            case .total: 1...256
            case .entries: 100...100_000
            case .expansion: 100...10_000
            }
        }

        var unit: String? {
            switch self {
            case .file, .total: "GiB"
            case .expansion: ":1"
            case .entries, .depth: nil
            }
        }

        var value: WritableKeyPath<AppSafetyLimits, Int> {
            switch self {
            case .file: \.entryGiB
            case .total: \.totalGiB
            case .entries: \.entries
            case .depth: \.depth
            case .expansion: \.expansion
            }
        }
    }

    let limits: AppSafetyLimits
    let save: (AppSafetyLimits) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @FocusState private var focused: Limit?
    @State private var draft: [Limit: String]

    init(limits: AppSafetyLimits, save: @escaping (AppSafetyLimits) -> Void) {
        self.limits = limits
        self.save = save
        _draft = State(initialValue: Self.fields(for: limits))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Limit.allCases, id: \.self) { limit in editor(limit) }
                } footer: {
                    Text("These limits apply to new archive operations.")
                }
                Section {
                    Button("Restore Defaults") {
                        focused = nil
                        draft = Self.fields(for: .defaults)
                    }
                    .disabled(editedLimits == .defaults)
                    .accessibilityIdentifier("settings-safety-reset")
                }
            }
            .modifier(WorkspaceListSurface())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Safety Limits")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .fontWeight(.semibold)
                        .disabled(editedLimits == nil)
                        .accessibilityIdentifier("settings-safety-save")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        .interactiveDismissDisabled(draft != Self.fields(for: limits))
    }

    private func editor(_ limit: Limit) -> some View {
        let input = draft[limit, default: ""]
        let showError = enteredValue(for: limit) == nil && (focused != limit || !input.isEmpty)
        let row = dynamicType.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return VStack(alignment: .leading, spacing: 6) {
            row {
                VStack(alignment: .leading, spacing: 3) {
                    Text(limit.title).font(.body.weight(.medium))
                    Text(limit.detail).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    TextField(limit.title, text: Binding(get: { draft[limit, default: ""] },
                                                          set: { draft[limit] = $0 }))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: limit)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onSubmit { focused = nil }
                        .accessibilityIdentifier("settings-limit-\(limit.rawValue)")
                    if let unit = limit.unit {
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                    if focused == limit && !input.isEmpty {
                        Button { draft[limit] = "" } label: {
                            Label("Clear Value", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-limit-clear-\(limit.rawValue)")
                    }
                }
                .modifier(WorkspaceInputWell(focused: focused == limit, invalid: showError))
                .frame(width: dynamicType.isAccessibilitySize ? nil : 132)
            }
            if showError {
                let minimum = limit.range.lowerBound.formatted()
                let maximum = limit.range.upperBound.formatted()
                Label("Enter a whole number from \(minimum) to \(maximum).", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings-limit-error-\(limit.rawValue)")
            }
        }
        .padding(.vertical, 5)
    }

    private static func fields(for values: AppSafetyLimits) -> [Limit: String] {
        Dictionary(uniqueKeysWithValues: Limit.allCases.map { ($0, String(values[keyPath: $0.value])) })
    }

    private func enteredValue(for limit: Limit) -> Int? {
        let text = draft[limit, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        guard let value = Int(normalized), limit.range.contains(value) else { return nil }
        return value
    }

    private var editedLimits: AppSafetyLimits? {
        var values = limits
        for limit in Limit.allCases {
            guard let value = enteredValue(for: limit) else { return nil }
            values[keyPath: limit.value] = value
        }
        return values
    }

    private func commit() {
        guard let editedLimits else { return }
        save(editedLimits)
        dismiss()
    }
}

private struct LicenseDocument: View {
    let name: String
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(name)
        .task {
            let main = name == "AetherUnzip"
            let url = Bundle.main.url(forResource: main ? "LICENSE" : name, withExtension: main ? nil : "txt")
            text = await Task.detached(priority: .utility) {
                url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }.value ?? String(localized: "License text is unavailable.")
        }
    }
}

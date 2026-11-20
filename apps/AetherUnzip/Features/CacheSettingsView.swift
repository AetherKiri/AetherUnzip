import SwiftUI

struct CacheSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CachePreferences.automaticCleanupKey) private var automaticCleanup = true
    @AppStorage(CachePreferences.previewLimitKey) private var previewLimit = CachePreferences.defaultPreviewLimit
    @AppStorage(CachePreferences.nestedLimitKey) private var nestedLimit = CachePreferences.defaultNestedLimit
    @State private var usage: PreviewCache.Usage?
    @State private var working = false
    @State private var status: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let usage {
                        LabeledContent("Space Used", value: formattedBytes(usage.bytes))
                        LabeledContent("Available to Clear", value: formattedBytes(usage.reclaimableBytes))
                            .accessibilityIdentifier("cache-reclaimable")
                    } else if working {
                        ProgressView()
                    }
                    Button("Clear Unused Cache", systemImage: "trash", role: .destructive) {
                        Task { await updateUsage(clearing: true) }
                    }
                    .disabled(working || (usage?.reclaimableCount ?? 0) == 0)
                    .accessibilityIdentifier("cache-clear")
                    if let status {
                        Label(status, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("cache-result")
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { await updateUsage() } }
                            .disabled(working)
                    }
                } header: {
                    Text("Archive Preview Cache")
                } footer: {
                    Text("Clears unused files generated for archive previews.")
                }
                Section {
                    Toggle("Clean Up Automatically", isOn: $automaticCleanup)
                        .accessibilityIdentifier("cache-automatic")
                } footer: {
                    Text("Clears unused previews left by interrupted sessions when the app becomes active.")
                }
                Section {
                    limitPicker("Single File Preview", selection: $previewLimit, sizes: CachePreferences.previewLimits)
                        .accessibilityIdentifier("cache-preview-limit")
                    limitPicker("Nested Archive Staging", selection: $nestedLimit, sizes: CachePreferences.nestedLimits)
                        .accessibilityIdentifier("cache-nested-limit")
                } header: {
                    Text("Temporary Space Limits")
                } footer: {
                    Text("Staging space is shared across each nested archive chain.")
                }
            }
            .modifier(WorkspaceListSurface())
            .modifier(WorkspaceCanvas())
            .navigationTitle("Cache Management")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
        .task { await updateUsage() }
    }

    private func limitPicker(_ title: LocalizedStringKey, selection: Binding<Int>, sizes: [Int]) -> some View {
        Picker(title, selection: selection) {
            ForEach(sizes, id: \.self) { size in Text("\(size) MiB").tag(size) }
        }
        .pickerStyle(.menu)
        .accessibilityValue(Text("\(selection.wrappedValue) MiB"))
    }

    private func updateUsage(clearing: Bool = false) async {
        guard !working else { return }
        working = true
        failure = nil
        status = nil
        defer { working = false }
        do {
            let result = try await PreviewCache.shared.usage(clearing: clearing)
            usage = result
            if clearing {
                status = result.removedBytes > 0
                    ? String(localized: "Cleared \(formattedBytes(result.removedBytes)) of preview files.")
                    : String(localized: "No unused preview files.")
            }
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
            usage = try? await PreviewCache.shared.usage()
        }
    }
}

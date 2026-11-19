import AetherUnzipKit
import SwiftUI

struct SettingsView: View {
    @Binding var conflict: ExtractionOptions.ConflictPolicy
    @Binding var destination: DestinationPolicy
    @Binding var entryLimitGiB: Int
    @Binding var totalLimitGiB: Int
    @Binding var entryCountLimit: Int
    @Binding var depthLimit: Int
    @Binding var expansionLimit: Int
    @State private var showLicenses = false
    @State private var showLimits = false

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
        .sheet(isPresented: $showLicenses) { licenses }
    }

    private var preferences: some View {
        List {
            Section("Extraction") {
                Picker(selection: $conflict) {
                    Text("Stop on conflict").tag(ExtractionOptions.ConflictPolicy.fail)
                    Text("Keep existing").tag(ExtractionOptions.ConflictPolicy.skip)
                    Text("Replace files").tag(ExtractionOptions.ConflictPolicy.replace)
                } label: {
                    Label("Existing Files", systemImage: "doc.on.doc")
                }
                Picker(selection: $destination) {
                    ForEach(DestinationPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label("Destination", systemImage: "folder")
                }
            }
            Section("Safety") {
                DisclosureGroup(isExpanded: $showLimits) {
                    Stepper("Per file: \(entryLimitGiB) GiB", value: $entryLimitGiB, in: 1...64)
                    Stepper("Total: \(totalLimitGiB) GiB", value: $totalLimitGiB, in: 1...256)
                    Stepper("Entries: \(entryCountLimit.formatted())", value: $entryCountLimit,
                            in: 100...100_000, step: 100)
                    Stepper("Path depth: \(depthLimit)", value: $depthLimit, in: 1...64)
                    Stepper("Expansion ratio: \(expansionLimit.formatted()):1", value: $expansionLimit,
                            in: 100...10_000, step: 100)
                } label: {
                    Label("Safety Limits", systemImage: "shield")
                }
            }
            Section("About") {
                LabeledContent {
                    Text(ArchiveService.coreVersion).monospacedDigit()
                } label: {
                    Label("AetherUnzip Core", systemImage: "info.circle")
                }
                Button { showLicenses = true } label: {
                    Label("Open-source Licenses", systemImage: "doc.text")
                }
            }
        }
        .modifier(WorkspaceListSurface())
        .pickerStyle(.menu)
    }

    private var licenses: some View {
        NavigationStack {
            List {
                ForEach(["AetherUnzip", "libarchive", "liblzma", "lz4", "zstd", "brotli"], id: \.self) { name in
                    NavigationLink(name) {
                        ScrollView {
                            Text(license(named: name))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(name)
                    }
                }
            }
            .navigationTitle("Open-source licenses")
            .toolbar { Button("Done") { showLicenses = false } }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private func license(named name: String) -> String {
        let url = Bundle.main.url(forResource: name == "AetherUnzip" ? "LICENSE" : name,
                                  withExtension: name == "AetherUnzip" ? nil : "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "License text is unavailable.")
        }
        return text
    }
}

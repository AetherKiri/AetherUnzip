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

    var body: some View {
        Form {
            Section("Extraction") {
                Picker("Existing files", selection: $conflict) {
                    Text("Stop on conflict").tag(ExtractionOptions.ConflictPolicy.fail)
                    Text("Keep existing").tag(ExtractionOptions.ConflictPolicy.skip)
                    Text("Replace files").tag(ExtractionOptions.ConflictPolicy.replace)
                }
                Picker("Destination", selection: $destination) {
                    ForEach(DestinationPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Safety limits") {
                Stepper("Per file: \(entryLimitGiB) GiB", value: $entryLimitGiB, in: 1...64)
                Stepper("Total: \(totalLimitGiB) GiB", value: $totalLimitGiB, in: 1...256)
                Stepper("Entries: \(entryCountLimit.formatted())", value: $entryCountLimit,
                        in: 100...100_000, step: 100)
                Stepper("Path depth: \(depthLimit)", value: $depthLimit, in: 1...64)
                Stepper("Expansion ratio: \(expansionLimit.formatted()):1", value: $expansionLimit,
                        in: 100...10_000, step: 100)
            }
            Section("About") {
                LabeledContent("AetherUnzip Core", value: ArchiveService.coreVersion)
                Button("Open-source licenses") { showLicenses = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showLicenses) {
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
    }

    private func license(named name: String) -> String {
        let url = Bundle.main.url(forResource: name == "AetherUnzip" ? "LICENSE" : name,
                                  withExtension: name == "AetherUnzip" ? nil : "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text is unavailable."
        }
        return text
    }
}

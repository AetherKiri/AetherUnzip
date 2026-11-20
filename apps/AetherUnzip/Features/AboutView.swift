import AetherUnzipKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    private static let version = bundleValue("CFBundleShortVersionString")
    private static let build = bundleValue("CFBundleVersion")
    private static let core = ArchiveService.coreVersion

    static var versionSummary: String? {
        version.map { String(localized: "Version \($0)") }
    }

    var body: some View {
        NavigationStack {
            List {
                identity
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 10, trailing: 4))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                Section {
                    versionRow("App Version", value: Self.version, identifier: "about-app-version")
                    versionRow("Build Number", value: Self.build, identifier: "about-build")
                    versionRow("AetherUnzip Core", value: Self.core, identifier: "about-core-version")
                }
                Section {
                    Button(action: copyVersions) {
                        Label {
                            Text(copied ? "Copied" : "Copy Version Info")
                                .contentTransition(reduceMotion ? .identity : .opacity)
                        } icon: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        }
                        .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: copied)
                    }
                    .accessibilityIdentifier("about-copy-versions")
                    NavigationLink {
                        LicenseNoticesView()
                    } label: {
                        Label("Open-source Licenses", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("about-licenses")
                }
            }
            .modifier(WorkspaceListSurface())
            .navigationTitle("About")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("about-done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 450)
        #endif
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { copied = false }
        }
    }

    private var identity: some View {
        HStack(spacing: 14) {
            WorkspaceGlyph(symbol: "archivebox", tint: .accentColor, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "AetherUnzip").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Archive and File Manager").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func versionRow(_ label: LocalizedStringKey, value: String?, identifier: String) -> some View {
        LabeledContent(label) {
            Text(verbatim: value ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)
        }
    }

    private static func bundleValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func copyVersions() {
        let version = Self.version ?? "—"
        let build = Self.build ?? "—"
        let core = Self.core
        let text = "AetherUnzip\n" + String(localized: "Version \(version) (Build \(build))") + "\n"
            + String(localized: "AetherUnzip Core \(core)")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        copied = true
        #endif
    }
}

private struct LicenseNotice: Identifiable, Sendable {
    let title: String
    let resource: String
    let fileExtension: String?
    let license: String

    var id: String { resource }

    static let application = Self(title: "AetherUnzip", resource: "LICENSE", fileExtension: nil, license: "MIT")
    static let dependencies: [Self] = [
        .init(title: "Brotli", resource: "brotli", fileExtension: "txt", license: "MIT"),
        .init(title: "libarchive", resource: "libarchive", fileExtension: "txt",
              license: String(localized: "BSD and bundled notices")),
        .init(title: "liblzma", resource: "liblzma", fileExtension: "txt", license: "0BSD"),
        .init(title: "LZ4", resource: "lz4", fileExtension: "txt", license: "BSD-2-Clause"),
        .init(title: "Zstandard", resource: "zstd", fileExtension: "txt", license: "BSD")
    ]
}

private struct LicenseNoticesView: View {
    var body: some View {
        List {
            Section("Application") {
                noticeRow(.application)
            }
            Section("Third-party Libraries") {
                ForEach(LicenseNotice.dependencies, content: noticeRow)
            }
        }
        .modifier(WorkspaceListSurface())
        .navigationTitle("Open-source Licenses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func noticeRow(_ notice: LicenseNotice) -> some View {
        NavigationLink {
            LicenseDocument(notice: notice)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: notice.title).font(.body.weight(.medium))
                Text(verbatim: notice.license).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("license-\(notice.id)")
    }
}

private struct LicenseDocument: View {
    let notice: LicenseNotice

    private enum Contents {
        case loading, document(String), unavailable
    }

    @State private var contents = Contents.loading

    var body: some View {
        Group {
            switch contents {
            case .loading:
                ProgressView()
            case .document(let text):
                ScrollView {
                    Text(verbatim: text)
                        .font(.callout)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                }
            case .unavailable:
                ContentUnavailableView("Can’t Open License", systemImage: "doc.text",
                                       description: Text("License text is unavailable."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(notice.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            let url = Bundle.main.url(forResource: notice.resource, withExtension: notice.fileExtension)
            let text = await Task.detached(priority: .utility) {
                url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }.value
            guard !Task.isCancelled else { return }
            contents = text.map(Contents.document) ?? .unavailable
        }
    }
}

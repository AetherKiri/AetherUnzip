import AetherUnzipKit
import SwiftUI

struct FormatSupportView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var supported: Set<ArchiveFormat>?
    @State private var failure: String?

    private enum Category: CaseIterable {
        case archives, streams, resources

        var title: LocalizedStringKey {
            switch self {
            case .archives: "Archives"
            case .streams: "Compressed Streams"
            case .resources: "Game Resources"
            }
        }

        var formats: [ArchiveFormat] {
            switch self {
            case .archives: [.zip, .sevenZip, .rar, .rar5, .tar, .cab, .iso9660, .lha]
            case .streams: [.gzip, .lz4, .zstandard, .xz, .bzip2, .brotli]
            case .resources: [.xp3]
            }
        }
    }

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Format Support Unavailable", systemImage: "doc.zipper",
                                       description: Text(failure))
            } else if let supported {
                if supported.isEmpty {
                    ContentUnavailableView("No Extraction Formats Available", systemImage: "doc.zipper")
                } else {
                    formatList(supported)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Supported Formats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            do { supported = try ArchiveService.supportedExtractionFormats() }
            catch { failure = error.localizedDescription }
        }
    }

    private func formatList(_ supported: Set<ArchiveFormat>) -> some View {
        List {
            ForEach(Category.allCases, id: \.self) { category in
                let formats = category.formats.filter { supported.contains($0) }
                if !formats.isEmpty {
                    Section(category.title) {
                        ForEach(formats, id: \.self, content: formatRow)
                    }
                }
            }
            Section {
                Text("Some variants require specific compression methods or encryption support.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .modifier(WorkspaceListSurface())
        .accessibilityIdentifier("supported-formats-list")
    }

    private func formatRow(_ format: ArchiveFormat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: format == .zip ? "ZIP / ZIP64" : format.description)
                    .font(.body.weight(.semibold))
                Text(details(for: format))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            supportBadge
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue("Supported")
        .accessibilityIdentifier("supported-format-\(format.rawValue)")
    }

    private var supportBadge: some View {
        let green = colorScheme == .dark
            ? Color(red: 0.50, green: 0.86, blue: 0.66)
            : Color(red: 0.10, green: 0.46, blue: 0.28)
        return Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(green)
            .frame(width: 24, height: 22)
            .background(green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }

    private func details(for format: ArchiveFormat) -> LocalizedStringKey {
        switch format {
        case .zip: "Deflate, ZipCrypto, WinZip AES-256, and split ZIP volumes."
        case .sevenZip: "LZMA2, AES-256, and numbered volumes. Encrypted BCJ2 is unsupported."
        case .rar: "Unencrypted single archives and volume sets."
        case .rar5: "AES-256 for single volumes, including encrypted file names. Volume sets require unencrypted files."
        case .tar: "USTAR archives (.tar)."
        case .cab: "Single-volume archives with MSZIP or LZX."
        case .iso9660: "ISO 9660 disc images with Rock Ridge support."
        case .lha: "LH7 files (.lha, .lzh)."
        case .gzip: "Standalone .gz files and compressed TAR archives."
        case .lz4: "Standalone .lz4 files and compressed TAR archives."
        case .zstandard: "Standalone .zst files and compressed TAR archives."
        case .xz: "Standalone .xz files and compressed TAR archives."
        case .bzip2: "Standalone .bz2 files and compressed TAR archives."
        case .brotli: "Standalone .br streams. Extracting .tar.br produces a TAR file."
        case .xp3: "Standard KiriKiri archives. Game-specific protected entries require dedicated support."
        case .unknown: ""
        }
    }
}

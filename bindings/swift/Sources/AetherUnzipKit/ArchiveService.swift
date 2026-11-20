import CAetherUnzip
import CryptoKit
import Foundation

public struct ExtractionTask: Sendable {
    public let progress: AsyncStream<ExtractionProgress>
    fileprivate let worker: Task<Int?, Error>
    fileprivate let control: OperationControl

    public func cancel() {
        control.cancel()
        worker.cancel()
    }

    public func value() async throws {
        _ = try await acceptedPasswordCandidateIndex()
    }

    /// The index in the supplied password candidates after a successful extraction.
    public func acceptedPasswordCandidateIndex() async throws -> Int? {
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancel()
        }
    }
}

public struct ArchiveService: Sendable {
    public init() {}

    public static var coreVersion: String { String(cString: aether_unzip_version()) }

    /// Formats registered by extraction drivers in the linked Core.
    /// Individual files can still require unsupported codecs or encryption methods.
    public static func supportedExtractionFormats() throws -> Set<ArchiveFormat> {
        try withContext { context in
            var formats: Set<ArchiveFormat> = []
            for index in 0..<aether_unzip_driver_count(context) {
                guard let driver = aether_unzip_driver_at(context, index)?.pointee,
                      ArchiveCapabilities(rawValue: driver.capabilities).contains(.extract),
                      let registered = driver.formats else { continue }
                for rawFormat in UnsafeBufferPointer(start: registered, count: Int(driver.format_count)) {
                    if let format = ArchiveFormat(rawValue: rawFormat), format != .unknown {
                        formats.insert(format)
                    }
                }
            }
            return formats
        }
    }

    /// Fingerprints the bytes of one archive or an ordered volume set for local password associations.
    public func archiveFingerprint(for urls: [URL], profile: FormatProfile? = nil) async throws -> String {
        let input: ArchiveInput
        if profile != nil {
            guard urls.count == 1, let url = urls.first else { throw ArchiveError.invalidInput }
            input = try ArchiveInput(profileURL: url)
        } else {
            input = try ArchiveInput(urls)
        }
        return try await fingerprint(input.urls, profile: profile, revisions: nil)
    }

    /// Fingerprints a file-backed manifest only if it still identifies the same file revisions.
    public func archiveFingerprint(for manifest: ArchiveManifest) async throws -> String {
        guard !manifest.isNested else { throw ArchiveError.unsupported }
        return try await fingerprint(manifest.sourceURLs, profile: manifest.profile, revisions: manifest.revisions)
    }

    public func open(_ url: URL, limits: ExtractionOptions.Limits = .init(),
                     passphrase: String? = nil) async throws
        -> ArchiveManifest {
        try await open([url], limits: limits, passphrase: passphrase)
    }

    /// Opens one archive or a matching set of ZIP, 7z or RAR volumes.
    public func open(_ urls: [URL], limits: ExtractionOptions.Limits = .init(),
                     passphrase: String? = nil) async throws
        -> ArchiveManifest {
        try await open(ArchiveInput(urls), profile: nil, limits: limits, passphrase: passphrase)
    }

    /// Divides a file selection into standalone archives and named sets of volumes.
    /// Opening each group still checks for missing parts and validates its contents.
    public func archiveGroups(in urls: [URL]) -> [[URL]] {
        ArchiveInput.groups(in: urls)
    }

    public func open(_ url: URL, profile: FormatProfile, limits: ExtractionOptions.Limits = .init(),
                     passphrase: String? = nil)
        async throws -> ArchiveManifest {
        try await open(ArchiveInput(profileURL: url), profile: profile, limits: limits, passphrase: passphrase)
    }

    /// Loads a versioned JSON profile from a coordinated Apple file URL.
    public func loadFormatProfile(_ url: URL) async throws -> FormatProfile {
        guard url.isFileURL else { throw ArchiveError.invalidInput }
        let control = OperationControl()
        if Task.isCancelled { control.cancel() }
        return try await withTaskCancellationHandler {
            try await coordinated(reading: [url], writing: nil, control: control) { urls, _ in
                guard let url = urls.first else { throw ArchiveError.invalidInput }
                let maximumSize = 16 * 1024
                return try withFiles([url]) { source in
                    var length: UInt64 = 0
                    try check(aether_unzip_source_length(source, &length))
                    guard length > 0, length <= maximumSize else { throw ArchiveError.invalidProfile }
                    var data = Data(count: Int(length))
                    try data.withUnsafeMutableBytes { buffer in
                        var count = 0
                        while count < buffer.count {
                            if control.isCancelled { throw ArchiveError.cancelled }
                            var actual = 0
                            try check(aether_unzip_source_read_at(source, UInt64(count),
                                buffer.baseAddress?.advanced(by: count), buffer.count - count, &actual))
                            guard actual > 0 else { throw ArchiveError.inputOutput }
                            count += actual
                        }
                    }
                    do { return try JSONDecoder().decode(FormatProfile.self, from: data) }
                    catch { throw ArchiveError.invalidProfile }
                }
            }
        } onCancel: { control.cancel() }
    }

    private func open(_ input: ArchiveInput, profile: FormatProfile?,
                      limits: ExtractionOptions.Limits, passphrase: String?) async throws -> ArchiveManifest {
        let control = OperationControl()
        if Task.isCancelled { control.cancel() }
        let worker = Task.detached(priority: .userInitiated) {
            try await coordinated(reading: input.urls, writing: nil, control: control) { urls, _ in
                let revisions = try urls.map(FileRevision.init)
                return try withSource(urls, passphrase: passphrase) { context, source in
                    var options = control.options(.init(limits: limits))
                    return try withOpenedInput(context, source, input.name, profile, &options) { payload, handle in
                        guard let info = aether_unzip_archive_info(handle)?.pointee else {
                            throw ArchiveError.invalidInput
                        }
                        let format = ArchiveFormat(rawValue: info.format) ?? .unknown
                        if let expected = input.format, expected != format,
                           !(expected == .rar && format == .rar5) {
                            throw ArchiveError.invalidVolumeSet
                        }
                        var entries: [ArchiveEntry] = []
                        try eachEntry(handle) {
                            entries.append($0)
                            return true
                        }
                        var compressedSize: UInt64 = 0
                        try check(aether_unzip_source_length(payload, &compressedSize))
                        return ArchiveManifest(
                            url: input.urls[0], sourceURLs: input.urls, displayName: input.name,
                            format: format,
                            compression: info.filter == 0 ? nil : ArchiveFormat(rawValue: info.filter),
                            isStream: info.kind == UInt32(AU_KIND_STREAM),
                            capabilities: .init(rawValue: info.capabilities),
                            compressedSize: compressedSize, entries: entries, profile: profile, revisions: revisions,
                            nestedSource: nil, openingPassphrase: passphrase.map(ArchivePassphrase.init)
                        )
                    }
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            control.cancel()
            worker.cancel()
        }
    }

    /// Opens a file as an archive, with a shared depth and staging budget along its ancestors.
    /// The resulting manifest owns the staged source until all copies are released.
    public func openNested(_ id: ArchiveEntry.ID, in parent: ArchiveManifest,
                           passphrase: String? = nil, childPassphrase: String? = nil,
                           maximumDepth: UInt32 = 3,
                           maximumStagedBytes: UInt64 = 256 * 1024 * 1024,
                           limits: ExtractionOptions.Limits = .init()) async throws -> ArchiveManifest {
        guard let index = Int(exactly: id), parent.entries.indices.contains(index) else {
            throw ArchiveError.missingEntry
        }
        let expected = parent.entries[index]
        guard expected.kind == .file else { throw ArchiveError.unsupported }
        let depth = min(maximumDepth, parent.nestedSource?.remainingDepth ?? maximumDepth)
        let bytes = min(maximumStagedBytes, parent.nestedSource?.remainingBytes ?? maximumStagedBytes)
        guard depth > 0, bytes > 0 else { throw ArchiveError.limitExceeded }
        let control = OperationControl()
        if Task.isCancelled { control.cancel() }
        return try await withTaskCancellationHandler {
            try await coordinated(reading: parent.coordinatedURLs, writing: nil, control: control) { urls, _ in
                try withManifestSource(parent, urls, passphrase: passphrase) { context, source in
                    var options = control.options(.init(limits: limits))
                    var mount: OpaquePointer?
                    try check(aether_unzip_resource_mount(context, source, parent.decoderName, &options, &mount))
                    guard let mount else { throw ArchiveError.invalidInput }
                    defer { aether_unzip_resource_unmount(mount) }
                    try check(aether_unzip_resource_build_index(mount, 16 * 1024 * 1024))
                    var found: UnsafePointer<au_entry>?
                    try check(aether_unzip_resource_lookup(mount, expected.path, &found))
                    guard found?.pointee.index == id else { throw ArchiveError.changed }

                    return try withContext(passphrase: childPassphrase) { childContext in
                        var child: OpaquePointer?
                        var nestedLimits = au_nested_limits(struct_size: UInt32(MemoryLayout<au_nested_limits>.size),
                                                            max_depth: depth, max_staged_bytes: bytes)
                        let scratch = FileManager.default.temporaryDirectory.path
                        try check(aether_unzip_resource_mount_nested(mount, expected.path, scratch,
                                                                     childContext, &nestedLimits, &child))
                        guard let child else { throw ArchiveError.invalidInput }
                        defer { aether_unzip_resource_unmount(child) }
                        guard let info = aether_unzip_resource_info(child)?.pointee else {
                            throw ArchiveError.invalidInput
                        }
                        var entries: [ArchiveEntry] = []
                        try eachEntry(child, next: aether_unzip_resource_next) {
                            entries.append($0)
                            return true
                        }
                        var staged: OpaquePointer?
                        try check(aether_unzip_resource_source(child, &staged))
                        guard let staged else { throw ArchiveError.inputOutput }
                        var size: UInt64 = 0
                        let sizeStatus = aether_unzip_source_length(staged, &size)
                        guard sizeStatus == AU_OK, size <= bytes else {
                            aether_unzip_source_close(staged)
                            try check(sizeStatus)
                            throw ArchiveError.limitExceeded
                        }
                        let storage = NestedArchiveSource(staged, remainingDepth: depth - 1,
                                                          remainingBytes: bytes - size)
                        return ArchiveManifest(url: parent.url, sourceURLs: parent.sourceURLs,
                            displayName: URL(fileURLWithPath: expected.path).lastPathComponent,
                            format: ArchiveFormat(rawValue: info.format) ?? .unknown,
                            compression: info.filter == 0 ? nil : ArchiveFormat(rawValue: info.filter),
                            isStream: info.kind == UInt32(AU_KIND_STREAM),
                            capabilities: .init(rawValue: info.capabilities), compressedSize: size,
                            entries: entries, profile: nil, revisions: parent.revisions, nestedSource: storage,
                            openingPassphrase: childPassphrase.map(ArchivePassphrase.init))
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// Iterates the cached manifest in archive order with no open Core handles.
    public func entries(in manifest: ArchiveManifest) -> AsyncStream<ArchiveEntry> {
        let iterator = ManifestIterator(manifest.entries)
        return AsyncStream(unfolding: {
            // The stream captures an actor to serialize calls from multiple iterators.
            await iterator.next()
        })
    }

    /// Lists the immediate children of a virtual directory built from ordered archive layers.
    public func listResources(in layers: [ResourceLayer], directory: String = "",
                              collisionPolicy: ResourceCollisionPolicy = .strict,
                              maximumNameBytes: Int = 16 * 1024 * 1024,
                              limits: ExtractionOptions.Limits = .init()) async throws -> [ResourceEntry] {
        guard !directory.utf8.contains(0) else { throw ArchiveError.invalidInput }
        return try await withComposition(layers, collisionPolicy, maximumNameBytes, limits) { mount in
            var cursor: OpaquePointer?
            try checkResource(aether_unzip_resource_directory_open(mount, directory, &cursor))
            guard let cursor else { throw ArchiveError.invalidInput }
            defer { aether_unzip_resource_directory_close(cursor) }
            var entries: [ResourceEntry] = []
            try eachEntry(cursor, next: aether_unzip_resource_directory_next, checkStatus: checkResource) {
                entries.append(ResourceEntry($0))
                return true
            }
            return entries
        }
    }

    /// Reads a virtual file in blocks from the layer that supplies the selected path.
    public func streamResource(_ path: String, in layers: [ResourceLayer], maximumBytes: UInt64,
                               collisionPolicy: ResourceCollisionPolicy = .strict,
                               maximumNameBytes: Int = 16 * 1024 * 1024,
                               limits: ExtractionOptions.Limits = .init(),
                               consume: @escaping @Sendable (Data) throws -> Void) async throws {
        guard !path.utf8.contains(0) else { throw ArchiveError.invalidInput }
        try await withComposition(layers, collisionPolicy, maximumNameBytes, limits) { mount in
            var file: OpaquePointer?
            try checkResource(aether_unzip_resource_open_path(mount, path, &file))
            guard let file else { throw ArchiveError.invalidInput }
            defer { aether_unzip_resource_close(file) }
            guard let metadata = aether_unzip_resource_file_entry(file) else { throw ArchiveError.invalidInput }
            try copyEntryBytes(file, entry: ArchiveEntry(metadata.pointee), maximumBytes: maximumBytes,
                               read: aether_unzip_resource_read, consume: consume)
        }
    }

    /// Reads one file into memory after validating the archive revision.
    /// Use streamEntry to consume large files without accumulating their bytes.
    public func readEntry(_ id: ArchiveEntry.ID, from manifest: ArchiveManifest,
                          maximumBytes: UInt64, passphrase: String? = nil,
                          limits: ExtractionOptions.Limits = .init()) async throws -> Data {
        try await withSelectedEntry(id, from: manifest, passphrase: passphrase, limits: limits) {
            handle, entry in
            var data = Data()
            try copyEntryBytes(handle, entry: entry, maximumBytes: maximumBytes) {
                data.append($0)
            }
            return data
        }
    }

    /// Delivers blocks in file order on a background file-access queue. The consumer
    /// runs before the next block is read. The call throws if final verification fails.
    public func streamEntry(_ id: ArchiveEntry.ID, from manifest: ArchiveManifest,
                            maximumBytes: UInt64, passphrase: String? = nil,
                            limits: ExtractionOptions.Limits = .init(),
                            consume: @escaping @Sendable (Data) throws -> Void) async throws {
        try await withSelectedEntry(id, from: manifest, passphrase: passphrase, limits: limits) {
            handle, entry in
            try copyEntryBytes(handle, entry: entry, maximumBytes: maximumBytes, consume: consume)
        }
    }

    private func withSelectedEntry<T: Sendable>(
        _ id: ArchiveEntry.ID, from manifest: ArchiveManifest,
        passphrase: String?, limits: ExtractionOptions.Limits,
        _ body: @escaping @Sendable (OpaquePointer, ArchiveEntry) throws -> T
    ) async throws -> T {
        guard let index = Int(exactly: id), manifest.entries.indices.contains(index) else {
            throw ArchiveError.missingEntry
        }
        let expected = manifest.entries[index]
        guard expected.kind == .file else { throw ArchiveError.unsupported }
        let control = OperationControl()
        if Task.isCancelled { control.cancel() }
        return try await withTaskCancellationHandler {
            try await coordinated(reading: manifest.coordinatedURLs, writing: nil, control: control) { urls, _ in
                try withManifestSource(manifest, urls, passphrase: passphrase) { context, source in
                    var options = control.options(.init(limits: limits))
                    return try withArchive(context, source, manifest.decoderName, &options) { handle in
                        var match: ArchiveEntry?
                        try eachEntry(handle) { entry in
                            guard entry.id == id else { return true }
                            match = entry
                            return false
                        }
                        guard match == expected else { throw ArchiveError.changed }
                        return try body(handle, expected)
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    public func extract(_ manifest: ArchiveManifest, to directory: URL,
                        selecting ids: Set<ArchiveEntry.ID>? = nil,
                        options: ExtractionOptions = .init()) -> ExtractionTask {
        extract(manifest, to: directory, selecting: ids, options: options, passwordCandidates: [])
    }

    /// Tries supplied candidates in order before writing files. Only password failures advance the search.
    public func extract(_ manifest: ArchiveManifest, to directory: URL,
                        selecting ids: Set<ArchiveEntry.ID>? = nil, options: ExtractionOptions = .init(),
                        passwordCandidates: [String]) -> ExtractionTask {
        let (progress, continuation) = AsyncStream.makeStream(
            of: ExtractionProgress.self, bufferingPolicy: .bufferingNewest(1))
        let control = OperationControl(progress: continuation,
                                       total: UInt64(ids?.count ?? manifest.entries.count))
        if Task.isCancelled { control.cancel() }
        let worker = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            if let ids, ids.isEmpty { throw ArchiveError.invalidInput }
            let selection = ids?.sorted() ?? []
            if let last = selection.last, last >= UInt64(manifest.entries.count) {
                throw ArchiveError.missingEntry
            }
            // Check passwords before writing any output so a retry can use the same folder.
            let verify = ids ?? Set(manifest.entries.lazy.filter(\.isEncrypted).map(\.id))
            let encrypted = manifest.entries.contains { verify.contains($0.id) && $0.kind == .file && $0.isEncrypted }
            return try await coordinated(reading: manifest.coordinatedURLs, writing: directory, control: control) { input, output in
                guard let output else { throw ArchiveError.invalidInput }
                func perform(_ password: String?, candidate: Int?) throws -> Int? {
                    var authenticated = false
                    do {
                        try withManifestSource(manifest, input, passphrase: password) { context, source in
                            var coreOptions = control.options(options)
                            if !verify.isEmpty {
                                try withArchive(context, source, manifest.decoderName, &coreOptions) { handle in
                                    var remaining = verify.count
                                    try eachEntry(handle) { entry in
                                        if verify.contains(entry.id) {
                                            guard let index = Int(exactly: entry.id),
                                                  manifest.entries.indices.contains(index),
                                                  entry == manifest.entries[index] else {
                                                throw ArchiveError.changed
                                            }
                                            if entry.isEncrypted && entry.kind == .file {
                                                try validatePassphrase(handle, checksAtEnd: candidate != nil || manifest.format == .sevenZip || manifest.format == .rar5)
                                            }
                                            remaining -= 1
                                        }
                                        return remaining != 0
                                    }
                                    guard remaining == 0 else { throw ArchiveError.changed }
                                }
                            }
                            authenticated = true
                            let status = selection.withUnsafeBufferPointer { indexes in
                                if let root = options.stripRoot {
                                    return root.withCString {
                                        aether_unzip_extract_stripping_root(context, source, manifest.decoderName,
                                            output.path, ids == nil ? nil : indexes.baseAddress, indexes.count,
                                            $0, &coreOptions)
                                    }
                                }
                                return aether_unzip_extract(context, source, manifest.decoderName,
                                    output.path, ids == nil ? nil : indexes.baseAddress, indexes.count, &coreOptions)
                            }
                            try check(status)
                        }
                        return candidate
                    } catch let error as ArchiveError where !authenticated && candidate != nil &&
                        (error == .encrypted || error == .incorrectPassphrase) {
                        throw RejectedPassword(error: error)
                    }
                }
                guard encrypted, !passwordCandidates.isEmpty else {
                    return try perform(options.passphrase, candidate: nil)
                }
                var rejection = ArchiveError.incorrectPassphrase
                for (index, password) in passwordCandidates.enumerated() {
                    if control.isCancelled { throw ArchiveError.cancelled }
                    do { return try perform(password, candidate: index) }
                    catch let rejected as RejectedPassword { rejection = rejected.error }
                }
                throw rejection
            }
        }
        return ExtractionTask(progress: progress, worker: worker, control: control)
    }
}

private func fingerprint(_ inputs: [URL], profile: FormatProfile?, revisions: [FileRevision]?) async throws -> String {
    let control = OperationControl()
    return try await withTaskCancellationHandler {
        try await coordinated(reading: inputs, writing: nil, control: control) { urls, _ in
            let initial = try urls.map(FileRevision.init)
            if let revisions, initial != revisions { throw ArchiveError.changed }
            var archive = SHA256()
            archive.update(data: Data("AetherUnzip archive fingerprint v1".utf8))
            var volumeCount = UInt64(urls.count).bigEndian
            withUnsafeBytes(of: &volumeCount) { archive.update(bufferPointer: $0) }
            for url in urls {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw ArchiveError.invalidInput
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                var volume = SHA256()
                while true {
                    if control.isCancelled { throw ArchiveError.cancelled }
                    guard let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
                    volume.update(data: bytes)
                }
                archive.update(data: Data(volume.finalize()))
            }
            guard try urls.map(FileRevision.init) == initial else { throw ArchiveError.changed }
            if let profile {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                archive.update(data: try encoder.encode(profile))
            }
            return archive.finalize().map { String(format: "%02x", $0) }.joined()
        }
    } onCancel: { control.cancel() }
}

private struct RejectedPassword: Error {
    let error: ArchiveError
}

private func validatePassphrase(_ handle: OpaquePointer, checksAtEnd: Bool) throws {
    var buffer = [UInt8](repeating: 0, count: checksAtEnd ? 65536 : 1)
    var count = 0
    repeat {
        try buffer.withUnsafeMutableBytes {
            try check(aether_unzip_archive_read(handle, $0.baseAddress, $0.count, &count))
        }
    } while checksAtEnd && count != 0
}

private func copyEntryBytes(_ handle: OpaquePointer, entry: ArchiveEntry, maximumBytes: UInt64,
                            read: (OpaquePointer?, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?) -> au_status
                                = aether_unzip_archive_read,
                            consume: (Data) throws -> Void) throws {
    if let size = entry.size, size > maximumBytes { throw ArchiveError.limitExceeded }
    var buffer = [UInt8](repeating: 0, count: 65536)
    var remaining = maximumBytes
    while true {
        var count = 0
        let data = try buffer.withUnsafeMutableBytes { storage -> Data? in
            // Read one byte past the allowance to distinguish EOF from excess data.
            let capacity = remaining < UInt64(storage.count) ? Int(remaining) + 1 : storage.count
            try check(read(handle, storage.baseAddress, capacity, &count))
            guard count > 0 else { return nil }
            guard UInt64(count) <= remaining, let address = storage.baseAddress else {
                throw ArchiveError.limitExceeded
            }
            return Data(bytes: address, count: count)
        }
        guard let data else { return }
        try consume(data)
        remaining -= UInt64(count)
    }
}

private struct ArchiveInput: Sendable {
    private enum Scheme: Hashable {
        case byteSplit(ArchiveFormat), diskZIP, numberedRAR, legacyRAR

        var format: ArchiveFormat {
            switch self {
            case .byteSplit(let format): format
            case .diskZIP: .zip
            case .numberedRAR, .legacyRAR: .rar
            }
        }

        var filenameExtension: String {
            switch self {
            case .byteSplit(.sevenZip): "7z"
            case .byteSplit, .diskZIP: "zip"
            case .numberedRAR, .legacyRAR: "rar"
            }
        }
    }

    private struct Part {
        let stem: String
        let scheme: Scheme
        let index: Int
    }

    private struct Group: Hashable {
        let folder: URL
        let stem: String
        let scheme: Scheme
    }

    static func groups(in urls: [URL]) -> [[URL]] {
        func explicitGroup(_ url: URL) -> Group? {
            guard let part = part(url) else { return nil }
            return Group(folder: url.deletingLastPathComponent().standardizedFileURL,
                         stem: part.stem, scheme: part.scheme)
        }
        let explicit = Set(urls.compactMap(explicitGroup))
        var result: [[URL]] = []
        var indexes: [Group: Int] = [:]
        for url in urls {
            var group = explicitGroup(url)
            let companionScheme: Scheme? = switch url.pathExtension.lowercased() {
            case "zip": .diskZIP
            case "rar": .legacyRAR
            default: nil
            }
            if group == nil, let scheme = companionScheme {
                let companion = Group(folder: url.deletingLastPathComponent().standardizedFileURL,
                                      stem: url.deletingPathExtension().lastPathComponent, scheme: scheme)
                if explicit.contains(companion) { group = companion }
            }
            if let group {
                if let index = indexes[group] {
                    result[index].append(url)
                    continue
                }
                indexes[group] = result.count
            }
            result.append([url])
        }
        return result
    }

    let urls: [URL]
    let name: String
    let format: ArchiveFormat?

    init(profileURL: URL) throws {
        guard profileURL.isFileURL else { throw ArchiveError.invalidInput }
        urls = [profileURL]
        name = profileURL.lastPathComponent
        format = nil
    }

    init(_ urls: [URL]) throws {
        guard let first = urls.first, urls.allSatisfy(\.isFileURL) else {
            throw ArchiveError.invalidInput
        }
        guard let firstPart = urls.lazy.compactMap(Self.part).first else {
            guard urls.count == 1 else { throw ArchiveError.invalidVolumeSet }
            self.urls = urls
            self.name = first.lastPathComponent
            self.format = nil
            return
        }

        var volumes: [Int: URL] = [:]
        var finalZIP: URL?
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let suffix = url.pathExtension.lowercased()
            if firstPart.scheme == .diskZIP, suffix == "zip", base == firstPart.stem {
                guard finalZIP == nil else { throw ArchiveError.invalidVolumeSet }
                finalZIP = url
                continue
            }
            let part = firstPart.scheme == .legacyRAR && suffix == "rar" && base == firstPart.stem
                ? Part(stem: base, scheme: .legacyRAR, index: 1)
                : Self.part(url)
            guard let part, part.index > 0, part.stem == firstPart.stem,
                  part.scheme == firstPart.scheme,
                  volumes.updateValue(url, forKey: part.index) == nil else {
                throw ArchiveError.invalidVolumeSet
            }
        }
        self.name = firstPart.stem + "." + firstPart.scheme.filenameExtension
        var ordered = try (0..<volumes.count).map { offset in
            let index = offset + 1
            guard let url = volumes[index] else {
                switch firstPart.scheme {
                case .diskZIP:
                    throw ArchiveError.missingVolumeFile(firstPart.stem + String(format: ".z%02d", index))
                case .legacyRAR:
                    let suffix = index == 1 ? ".rar" : String(format: ".r%02d", index - 2)
                    throw ArchiveError.missingVolumeFile(firstPart.stem + suffix)
                default:
                    throw ArchiveError.missingVolume(index)
                }
            }
            return url
        }
        if firstPart.scheme == .diskZIP {
            guard let finalZIP else { throw ArchiveError.missingVolumeFile(name) }
            ordered.append(finalZIP)
        }
        self.urls = ordered
        self.format = firstPart.scheme.format
    }

    private static func part(_ url: URL) -> Part? {
        let suffix = url.pathExtension.lowercased()
        let original = url.deletingPathExtension()
        if suffix.first == "z", let index = number(suffix.dropFirst(), atLeast: 2) {
            return Part(stem: original.lastPathComponent, scheme: .diskZIP, index: index)
        }
        if suffix.first == "r", suffix.count == 3,
           let index = number(suffix.dropFirst(), atLeast: 2) {
            return Part(stem: original.lastPathComponent, scheme: .legacyRAR, index: index + 2)
        }
        if suffix == "rar" {
            let part = original.pathExtension.lowercased()
            if part.hasPrefix("part"), let index = number(part.dropFirst(4), atLeast: 1) {
                return Part(stem: original.deletingPathExtension().lastPathComponent,
                            scheme: .numberedRAR, index: index)
            }
        }
        guard let index = number(suffix[...], atLeast: 3) else { return nil }
        let scheme: Scheme
        switch original.pathExtension.lowercased() {
        case "zip": scheme = .byteSplit(.zip)
        case "7z": scheme = .byteSplit(.sevenZip)
        default: return nil
        }
        return Part(stem: original.deletingPathExtension().lastPathComponent, scheme: scheme, index: index)
    }

    private static func number(_ value: Substring, atLeast minimum: Int) -> Int? {
        guard value.utf8.count >= minimum, value.utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return Int(value)
    }
}

private actor ManifestIterator {
    var iterator: IndexingIterator<[ArchiveEntry]>
    init(_ entries: [ArchiveEntry]) { iterator = entries.makeIterator() }
    func next() -> ArchiveEntry? { Task.isCancelled ? nil : iterator.next() }
}

// Only the cancellation bit is mutable and it is protected by NSLock. The
// continuation is Sendable. Core handles stay on the synchronous worker stack.
fileprivate final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let progress: AsyncStream<ExtractionProgress>.Continuation?
    let total: UInt64

    init(progress: AsyncStream<ExtractionProgress>.Continuation? = nil, total: UInt64 = 0) {
        self.progress = progress
        self.total = total
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func options(_ input: ExtractionOptions) -> au_options {
        var options = aether_unzip_options_default()
        options.conflict_policy = UInt32(input.conflictPolicy.rawValue)
        options.max_entry_bytes = input.limits.maxEntryBytes
        options.max_total_bytes = input.limits.maxTotalBytes
        options.max_entries = input.limits.maxEntries
        options.max_path_depth = input.limits.maxPathDepth
        options.max_expansion_ratio = input.limits.maxExpansionRatio
        options.user = Unmanaged.passUnretained(self).toOpaque()
        options.cancel = { data in
            guard let data else { return 0 }
            return Unmanaged<OperationControl>.fromOpaque(data).takeUnretainedValue().isCancelled ? 1 : 0
        }
        if progress != nil {
            options.progress = { data, entry, bytes, entryBytes, done in
                guard let data, let entry else { return }
                let control = Unmanaged<OperationControl>.fromOpaque(data).takeUnretainedValue()
                control.progress?.yield(.init(currentEntry: ArchiveEntry(entry.pointee),
                                              bytesWritten: bytes, entryBytesWritten: entryBytes,
                                              entriesDone: done,
                                              totalEntries: control.total))
            }
        }
        return options
    }
}

private func check(_ status: au_status) throws {
    if status != AU_OK { throw ArchiveError(status) }
}

private func checkResource(_ status: au_status) throws {
    if status == AU_EXISTS { throw ArchiveError.ambiguousResource }
    try check(status)
}

private func withComposition<T: Sendable>(
    _ layers: [ResourceLayer], _ policy: ResourceCollisionPolicy, _ maximumNameBytes: Int,
    _ limits: ExtractionOptions.Limits, _ body: @escaping @Sendable (OpaquePointer) throws -> T
) async throws -> T {
    guard !layers.isEmpty, maximumNameBytes >= 0, layers.allSatisfy({ !$0.prefix.utf8.contains(0) }) else {
        throw ArchiveError.invalidInput
    }
    var seen = Set<URL>()
    let inputs = layers.flatMap(\.archive.coordinatedURLs).filter { seen.insert($0).inserted }
    let control = OperationControl()
    if Task.isCancelled { control.cancel() }
    return try await withTaskCancellationHandler {
        try await coordinated(reading: inputs, writing: nil, control: control) { urls, _ in
            let coordinatedURLs = Dictionary(uniqueKeysWithValues: zip(inputs, urls))
            var coreLayers: [au_resource_layer] = []
            defer {
                for layer in coreLayers {
                    aether_unzip_resource_unmount(layer.mount)
                    free(UnsafeMutablePointer(mutating: layer.prefix))
                }
            }
            var options = control.options(.init(limits: limits))
            var remainingEntries = limits.maxEntries
            var remainingNameBytes = maximumNameBytes
            for layer in layers {
                let input = try layer.archive.coordinatedURLs.map { url in
                    guard let coordinated = coordinatedURLs[url] else { throw ArchiveError.inputOutput }
                    return coordinated
                }
                guard let prefix = strdup(layer.prefix) else { throw ArchiveError.outOfMemory }
                var mount: OpaquePointer?
                do {
                    var layerOptions = options
                    layerOptions.max_entries = max(1, remainingEntries)
                    try withManifestSource(layer.archive, input, passphrase: layer.passphrase) { context, source in
                        try check(aether_unzip_resource_mount(context, source, layer.archive.decoderName,
                                                             &layerOptions, &mount))
                    }
                    try check(aether_unzip_resource_build_index(mount, remainingNameBytes))
                    var indexedCount = 0, nameBytes = 0
                    try check(aether_unzip_resource_index_size(mount, &indexedCount, &nameBytes))
                    guard UInt64(indexedCount) <= remainingEntries else { throw ArchiveError.limitExceeded }
                    remainingEntries -= UInt64(indexedCount)
                    remainingNameBytes -= nameBytes
                } catch {
                    aether_unzip_resource_unmount(mount)
                    free(prefix)
                    throw error
                }
                coreLayers.append(.init(struct_size: UInt32(MemoryLayout<au_resource_layer>.size),
                                        mount: mount, prefix: UnsafePointer(prefix)))
            }
            var mount: OpaquePointer?
            try coreLayers.withUnsafeBufferPointer { layers in
                try check(aether_unzip_resource_compose(layers.baseAddress, layers.count, policy.coreValue,
                                                       maximumNameBytes, &options, &mount))
            }
            guard let mount else { throw ArchiveError.invalidInput }
            defer { aether_unzip_resource_unmount(mount) }
            return try body(mount)
        }
    } onCancel: {
        control.cancel()
    }
}

private func withContext<T>(passphrase: String? = nil,
                            _ body: (OpaquePointer) throws -> T) throws -> T {
    var context: OpaquePointer?
    if let passphrase {
        guard !passphrase.utf8.contains(0) else { throw ArchiveError.invalidInput }
        try check(aether_unzip_context_create_with_passphrase(passphrase, &context))
    } else {
        try check(aether_unzip_context_create(&context))
    }
    guard let context else { throw ArchiveError.invalidInput }
    defer { aether_unzip_context_destroy(context) }
    return try body(context)
}

private func withManifestSource<T>(_ manifest: ArchiveManifest, _ urls: [URL], passphrase: String?,
                                   _ body: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
    let passphrase = passphrase ?? manifest.openingPassphrase?.value
    if let storage = manifest.nestedSource {
        return try withContext(passphrase: passphrase) { context in
            try storage.access { source in try body(context, source) }
        }
    }
    guard try urls.map(FileRevision.init) == manifest.revisions else { throw ArchiveError.changed }
    return try withSource(urls, passphrase: passphrase) { context, source in
        guard let profile = manifest.profile else { return try body(context, source) }
        var payload: OpaquePointer?
        try profile.withCore(name: manifest.displayName) {
            try check(aether_unzip_profile_slice(source, &$0, &payload))
        }
        guard let payload else { throw ArchiveError.invalidInput }
        defer { aether_unzip_source_close(payload) }
        return try body(context, payload)
    }
}

private func withSource<T>(_ urls: [URL], passphrase: String? = nil,
                           _ body: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
    try withContext(passphrase: passphrase) { context in
        try withFiles(urls) { source in try body(context, source) }
    }
}

private func withFiles<T>(_ urls: [URL], _ body: (OpaquePointer) throws -> T) throws -> T {
    var sources: [OpaquePointer?] = []
    defer { for source in sources { aether_unzip_source_close(source) } }
    for url in urls {
        var source: OpaquePointer?
        try check(aether_unzip_source_file(url.path, &source))
        guard let source else { throw ArchiveError.inputOutput }
        sources.append(source)
    }
    if sources.count == 1, let source = sources[0] { return try body(source) }
    var combined: OpaquePointer?
    try sources.withUnsafeBufferPointer {
        try check(aether_unzip_source_concat($0.baseAddress, $0.count, &combined))
    }
    guard let combined else { throw ArchiveError.inputOutput }
    defer { aether_unzip_source_close(combined) }
    return try body(combined)
}

private func withOpenedInput<T>(_ context: OpaquePointer, _ source: OpaquePointer, _ name: String,
                                _ profile: FormatProfile?, _ options: inout au_options,
                                _ body: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
    guard let profile else {
        return try withArchive(context, source, name, &options, catalog: true) { archive in
            try body(source, archive)
        }
    }
    var payload: OpaquePointer?
    try profile.withCore(name: name) {
        try check(aether_unzip_profile_slice(source, &$0, &payload))
    }
    guard let payload else { throw ArchiveError.invalidInput }
    defer { aether_unzip_source_close(payload) }
    return try withArchive(context, payload, profile.payloadName ?? name, &options, catalog: true) { archive in
        guard aether_unzip_archive_info(archive)?.pointee.format == profile.expectedFormat.rawValue else {
            throw ArchiveError.profileMismatch
        }
        return try body(payload, archive)
    }
}

private func withArchive<T>(_ context: OpaquePointer, _ source: OpaquePointer, _ name: String,
                            _ options: inout au_options, catalog: Bool = false,
                            _ body: (OpaquePointer) throws -> T) throws -> T {
    var archive: OpaquePointer?
    if catalog {
        try check(aether_unzip_archive_open_catalog(context, source, name, &options, &archive))
    } else {
        try check(aether_unzip_archive_open(context, source, name, &options, &archive))
    }
    guard let archive else { throw ArchiveError.invalidInput }
    defer { aether_unzip_archive_close(archive) }
    return try body(archive)
}

private func eachEntry(_ handle: OpaquePointer,
                       next: (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<au_entry>?>?) -> au_status
                           = aether_unzip_archive_next_entry,
                       checkStatus: (au_status) throws -> Void = check,
                       _ body: (ArchiveEntry) throws -> Bool) throws {
    while true {
        var entry: UnsafePointer<au_entry>?
        let status = next(handle, &entry)
        if status == AU_END { return }
        try checkStatus(status)
        guard let entry else { throw ArchiveError.invalidInput }
        if try !body(ArchiveEntry(entry.pointee)) { return }
    }
}

private func coordinated<T: Sendable>(reading inputs: [URL], writing output: URL?,
                                        control: OperationControl,
                                        _ body: @escaping @Sendable ([URL], URL?) throws -> T) async throws -> T {
    guard output?.isFileURL != false else { throw ArchiveError.invalidInput }
    if control.isCancelled { throw ArchiveError.cancelled }
    let scopedURLs = (inputs + [output].compactMap { $0 }).filter {
        $0.startAccessingSecurityScopedResource()
    }
    defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    let reads = inputs.map { NSFileAccessIntent.readingIntent(with: $0, options: []) }
    let write = output.map { NSFileAccessIntent.writingIntent(with: $0, options: []) }
    nonisolated(unsafe) let coordinator = NSFileCoordinator()
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return try await withTaskCancellationHandler {
        let result: T = try await withCheckedThrowingContinuation { continuation in
            let accessor: @Sendable (Error?) -> Void = { error in
                do {
                    if control.isCancelled { throw ArchiveError.cancelled }
                    if let error {
                        if (error as? CocoaError)?.code == .userCancelled { throw ArchiveError.cancelled }
                        if ArchiveError.isOutOfSpace(error) { throw ArchiveError.insufficientSpace }
                        throw ArchiveError.fileAccess(error.localizedDescription)
                    }
                    continuation.resume(returning: try body(reads.map(\.url), write?.url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let intents = reads + [write].compactMap { $0 }
            if intents.isEmpty || control.isCancelled { queue.addOperation { accessor(nil) } }
            else { coordinator.coordinate(with: intents, queue: queue, byAccessor: accessor) }
        }
        return withExtendedLifetime(coordinator) { result }
    } onCancel: {
        control.cancel()
        coordinator.cancel()
    }
}

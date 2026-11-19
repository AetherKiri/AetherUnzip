import Foundation
import Testing
import AetherUnzipKit

struct ArchiveServiceTests {
    private let service = ArchiveService()

    @Test func opensSevenZipWithEncryptedNamesAndReusesThePassword() async throws {
        let url = try #require(Bundle.module.url(forResource: "7z-aes-header", withExtension: "7z",
                                                subdirectory: "Fixtures"))
        await #expect(throws: ArchiveError.encrypted) { try await service.open(url) }
        await #expect(throws: ArchiveError.incorrectPassphrase) {
            try await service.open(url, passphrase: "wrong-password")
        }
        let archive = try await service.open(url, passphrase: "档案🔑")
        #expect(archive.format == .sevenZip && archive.hasOpeningPassphrase)
        #expect(!String(reflecting: archive).contains("档案🔑"))
        #expect(archive.entries.map(\.path) == ["private.txt", "second.txt"])
        let entry = try #require(archive.entries.last)
        let bytes = Data("Another protected document\n".utf8)
        #expect(try await service.readEntry(entry.id, from: archive, maximumBytes: 64) == bytes)
        try await temporaryDirectory { output in
            try await service.extract(archive, to: output, selecting: [entry.id]).value()
            #expect(try Data(contentsOf: output.appending(path: entry.path)) == bytes)
        }
    }

    @Test(arguments: ["7z-aes-stored", "7z-aes-solid"])
    func extractsSevenZipWithVisibleNames(_ name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "7z",
                                                subdirectory: "Fixtures"))
        let archive = try await service.open(url)
        #expect(archive.capabilities.contains(.encryption))
        #expect(archive.entries.count == 2 && archive.entries.allSatisfy(\.isEncrypted))
        try await temporaryDirectory { output in
            let bad = service.extract(archive, to: output, options: .init(passphrase: "wrong-password"))
            await #expect(throws: ArchiveError.incorrectPassphrase) { try await bad.value() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
            let task = service.extract(archive, to: output, options: .init(passphrase: "fixture-pass"))
            try await task.value()
            #expect(try String(contentsOf: output.appending(path: "private.txt"), encoding: .utf8)
                    == "Protected document\n")
            #expect(try String(contentsOf: output.appending(path: "second.txt"), encoding: .utf8)
                    == "Another protected document\n")
        }
    }

    @Test func opensNestedSevenZipWithSeparatePasswords() async throws {
        let outer = try await service.open(fixture("7z-aes-nested"))
        let package = try #require(outer.entries.first)
        #expect(package.isEncrypted)
        await #expect(throws: ArchiveError.encrypted) {
            try await service.openNested(package.id, in: outer, childPassphrase: "档案🔑")
        }
        await #expect(throws: ArchiveError.incorrectPassphrase) {
            try await service.openNested(package.id, in: outer, passphrase: "parent-pass",
                                         childPassphrase: "wrong-password")
        }
        let inner = try await service.openNested(package.id, in: outer, passphrase: "parent-pass",
                                                 childPassphrase: "档案🔑")
        #expect(inner.isNested && inner.hasOpeningPassphrase && inner.format == .sevenZip)
        let entry = try #require(inner.entries.first)
        #expect(try await service.readEntry(entry.id, from: inner, maximumBytes: 64)
                == Data("Protected document\n".utf8))
    }

    @Test func opensAndExtractsAProfileWrappedPayload() async throws {
        let file = try #require(Bundle.module.url(forResource: "profile-box", withExtension: "bin",
                                                  subdirectory: "Fixtures"))
        let definition = try #require(Bundle.module.url(forResource: "format-profile", withExtension: "json",
                                                        subdirectory: "Fixtures"))
        let profile = try await service.loadFormatProfile(definition)
        let encoded = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(FormatProfile.self, from: encoded) == profile)
        let archive = try await service.open(file, profile: profile)
        #expect(archive.profile == profile)
        #expect(archive.format == .zip && archive.compressedSize == profile.payloadLength)
        let entry = try #require(archive.entries.first { $0.path == "notes.txt" })
        let bytes = try await service.readEntry(entry.id, from: archive, maximumBytes: 32)
        #expect(bytes == Data("AetherUnzip fixture\n".utf8))
        let entries = try await service.listResources(in: [ResourceLayer(archive, prefix: "box")], directory: "box")
        #expect(entries.map(\.path) == ["box/docs", "box/notes.txt"])
        try await temporaryDirectory { directory in
            try await service.extract(archive, to: directory, selecting: [entry.id]).value()
            #expect(try Data(contentsOf: directory.appending(path: "notes.txt")) == bytes)
            let bad = directory.appending(path: "oversized.json")
            try Data(repeating: 32, count: 16_385).write(to: bad)
            await #expect(throws: ArchiveError.invalidProfile) { try await service.loadFormatProfile(bad) }
        }
        let wrong = try FormatProfile(signatureHex: profile.signatureHex, signatureOffset: profile.signatureOffset,
            payloadOffset: profile.payloadOffset, payloadLength: profile.payloadLength, expectedFormat: .tar)
        await #expect(throws: ArchiveError.profileMismatch) { try await service.open(file, profile: wrong) }
        #expect(throws: ArchiveError.invalidProfile) {
            try FormatProfile(signatureHex: "GG", payloadOffset: 8, expectedFormat: .zip)
        }
    }

    @Test func combinesResourceLayersAndStreamsTheWinningEntry() async throws {
        let base = try await service.open(fixture())
        let xp3 = try #require(Bundle.module.url(forResource: "sample", withExtension: "xp3",
                                                subdirectory: "Fixtures"))
        let patch = try await service.open(xp3)
        let layers = [ResourceLayer(base), ResourceLayer(patch), ResourceLayer(base, prefix: "backup")]
        let docs = try await service.listResources(in: layers, directory: "docs")
        #expect(docs.map(\.path) == ["docs/readme.txt", "docs/样本📦.txt", "docs/空白.txt"])
        await #expect(throws: ArchiveError.ambiguousResource) {
            try await service.streamResource("notes.txt", in: layers, maximumBytes: 32) { _ in }
        }
        await #expect(throws: ArchiveError.limitExceeded) {
            try await service.listResources(in: layers, maximumNameBytes: 48)
        }
        enum ConsumerFailure: Error { case interrupted }
        await #expect(throws: ConsumerFailure.interrupted) {
            try await service.streamResource("notes.txt", in: layers, maximumBytes: 32,
                                             collisionPolicy: .preferLast) { chunk in
                #expect(chunk == Data("AetherUnzip fixture\n".utf8))
                throw ConsumerFailure.interrupted
            }
        }
        let protected = try await service.open(fixture("aes256"))
        let encryptedLayer = ResourceLayer(protected, prefix: "encrypted", passphrase: "fixture-pass")
        try await temporaryDirectory { directory in
            let output = directory.appending(path: "result")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try await service.streamResource("encrypted/private.txt", in: layers + [encryptedLayer],
                                             maximumBytes: 32) { try handle.write(contentsOf: $0) }
            #expect(try Data(contentsOf: output) == Data("Protected document\n".utf8))
        }
        let outer = try await service.open(fixture("nested"))
        let package = try #require(outer.entries.first { $0.path == "visible.zip" })
        let inner = try await service.openNested(package.id, in: outer)
        let stagedLayers = [ResourceLayer(inner, prefix: "staged")]
        let staged = try await service.listResources(in: stagedLayers, directory: "staged")
        #expect(staged.map(\.path) == ["staged/deep.zip"])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.listResources(in: stagedLayers)
        }
        await #expect(throws: ArchiveError.cancelled) { try await cancelled.value }
    }

    @Test func opensAndExtractsXP3ByContent() async throws {
        let sample = try #require(Bundle.module.url(forResource: "sample", withExtension: "xp3",
                                                   subdirectory: "Fixtures"))
        try await temporaryDirectory { directory in
            let disguised = directory.appending(path: "game-data.bin")
            try FileManager.default.copyItem(at: sample, to: disguised)
            let manifest = try await service.open(disguised)
            #expect(manifest.format == .xp3)
            let entry = try #require(manifest.entries.first { $0.path == "docs/样本📦.txt" })
            let expected = Data(("Stored prefix\n" + String(repeating: "XP3 resource line\n", count: 12000)).utf8)
            let bytes = try await service.readEntry(entry.id, from: manifest, maximumBytes: UInt64(expected.count))
            #expect(bytes == expected)
            let output = directory.appending(path: "Output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let task = service.extract(manifest, to: output, selecting: [entry.id])
            try await task.value()
            #expect(try Data(contentsOf: output.appending(path: entry.path)) == expected)
        }
    }

    @Test func opensAnEmbeddedArchiveAndExtractsFromItsStagedSource() async throws {
        let outer = try await service.open(fixture("nested"))
        let package = try #require(outer.entries.first { $0.path == "packages/内层.bin" })
        let plain = try #require(outer.entries.first { $0.path == "plain.txt" })
        await #expect(throws: ArchiveError.unknownFormat) {
            try await service.openNested(plain.id, in: outer)
        }
        await #expect(throws: ArchiveError.limitExceeded) {
            try await service.openNested(package.id, in: outer, maximumStagedBytes: 1)
        }
        let middle = try await service.openNested(package.id, in: outer, maximumDepth: 2)
        #expect(middle.isNested && middle.format == .zip && middle.displayName == "内层.bin")
        let deep = try #require(middle.entries.first)
        let inner = try await service.openNested(deep.id, in: middle)
        let note = try #require(inner.entries.first { $0.path == "notes.txt" })
        let bytes = try await service.readEntry(note.id, from: inner, maximumBytes: 32)
        #expect(bytes == Data("AetherUnzip fixture\n".utf8))
        await #expect(throws: ArchiveError.limitExceeded) {
            try await service.openNested(note.id, in: inner, maximumDepth: 8)
        }
        try await temporaryDirectory { output in
            let task = service.extract(inner, to: output, selecting: [note.id])
            try await task.value()
            #expect(try Data(contentsOf: output.appending(path: "notes.txt")) == bytes)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.openNested(package.id, in: outer)
        }
        await #expect(throws: ArchiveError.cancelled) { try await cancelled.value }
    }

    @Test func readsOneEntryWithAnExactByteBudget() async throws {
        let archive = try await service.open(fixture())
        let entry = try #require(archive.entries.first { $0.path == "docs/readme.txt" })
        let expected = Data("Nested document\n".utf8)
        let actual = try await service.readEntry(entry.id, from: archive,
                                                 maximumBytes: UInt64(expected.count))
        #expect(actual == expected)
        await #expect(throws: ArchiveError.limitExceeded) {
            try await service.readEntry(entry.id, from: archive, maximumBytes: 1)
        }
        await #expect(throws: ArchiveError.missingEntry) {
            try await service.readEntry(UInt64.max, from: archive, maximumBytes: 32)
        }
        let empty = try #require(archive.entries.first { $0.size == 0 })
        let data = try await service.readEntry(empty.id, from: archive, maximumBytes: 0)
        #expect(data.isEmpty)
    }

    @Test func streamsMultipleBlocksAndPropagatesConsumerErrors() async throws {
        enum ConsumerError: Error { case stopped }
        let archive = try await service.open(fixture("expansion"))
        let entry = try #require(archive.entries.first)
        try await temporaryDirectory { directory in
            let file = directory.appending(path: "entry")
            try Data().write(to: file)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try await service.streamEntry(entry.id, from: archive, maximumBytes: 220_000) { chunk in
                #expect(chunk.count <= 65_536)
                try handle.write(contentsOf: chunk)
            }
            #expect(try Data(contentsOf: file) == Data(repeating: 120, count: 220_000))
        }
        await #expect(throws: ConsumerError.stopped) {
            try await service.streamEntry(entry.id, from: archive, maximumBytes: 220_000) { _ in
                throw ConsumerError.stopped
            }
        }
    }

    @Test func readsProtectedEntriesAndHonorsCancellation() async throws {
        let archive = try await service.open(fixture("aes256"))
        let entry = try #require(archive.entries.first { $0.isEncrypted })
        await #expect(throws: ArchiveError.encrypted) {
            try await service.readEntry(entry.id, from: archive, maximumBytes: 64)
        }
        await #expect(throws: ArchiveError.incorrectPassphrase) {
            try await service.readEntry(entry.id, from: archive, maximumBytes: 64,
                                        passphrase: "wrong-password")
        }
        let content = try await service.readEntry(entry.id, from: archive, maximumBytes: 64,
                                                  passphrase: "fixture-pass")
        #expect(content == Data("Protected document\n".utf8))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.readEntry(entry.id, from: archive, maximumBytes: 64)
        }
        await #expect(throws: ArchiveError.cancelled) { try await cancelled.value }
    }

    @Test func opensAndEnumeratesThroughCore() async throws {
        #expect(ArchiveService.coreVersion == "0.1.0")
        let archive = try await service.open(fixture())
        #expect(archive.format == .zip)
        #expect(archive.capabilities.contains(.extract))
        #expect(!archive.capabilities.contains(.seek))
        #expect(archive.compressedSize > 0)
        let names = ["notes.txt", "docs/readme.txt", "docs/空白.txt"]
        #expect(archive.entries.map(\.path) == names)
        var streamed: [String] = []
        for await entry in service.entries(in: archive) { streamed.append(entry.path) }
        #expect(streamed == names)
    }

    @Test func extractsSelectedEntriesAndReportsProgress() async throws {
        try await temporaryDirectory { destination in
            let archive = try await service.open(fixture())
            let entry = try #require(archive.entries.first { $0.path == "docs/readme.txt" })
            let task = service.extract(archive, to: destination, selecting: [entry.id])
            var final: ExtractionProgress?
            for await progress in task.progress { final = progress }
            try await task.value()
            #expect(final?.entriesDone == 1)
            #expect(final?.fractionCompleted == 1)
            let file = destination.appending(path: entry.path)
            #expect(try String(contentsOf: file, encoding: .utf8) == "Nested document\n")
            #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "notes.txt").path))

            let conflict = service.extract(archive, to: destination, selecting: [entry.id])
            await #expect(throws: ArchiveError.conflict) { try await conflict.value() }
        }
    }

    @Test func opensWrongExtensionAndMapsErrors() async throws {
        try await temporaryDirectory { directory in
            let archive = directory.appending(path: "archive.dat")
            try FileManager.default.copyItem(at: fixture(), to: archive)
            #expect(try await service.open(archive).format == .zip)

            let unknown = directory.appending(path: "imposter.zip")
            try Data("not an archive".utf8).write(to: unknown)
            await #expect(throws: ArchiveError.unknownFormat) { try await service.open(unknown) }

            let corrupt = directory.appending(path: "corrupt.zip")
            try Data([80, 75, 3, 4]).write(to: corrupt)
            await #expect(throws: ArchiveError.corrupt) { try await service.open(corrupt) }
            try FileManager.default.removeItem(at: archive)
        }
    }

    @Test func cancellationAndLimitsReachCore() async throws {
        try await temporaryDirectory { destination in
            let archive = try await service.open(fixture("expansion"))
            var options = ExtractionOptions()
            options.limits.maxEntryBytes = 1024
            let limited = service.extract(archive, to: destination, options: options)
            await #expect(throws: ArchiveError.limitExceeded) { try await limited.value() }

            // A task created inside a pre-cancelled parent exercises the SDK's cancellation bridge.
            let caller = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                let task = service.extract(archive, to: destination)
                try await task.value()
            }
            await #expect(throws: ArchiveError.cancelled) { try await caller.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    @Test func changedArchiveRequiresNewPreview() async throws {
        try await temporaryDirectory { directory in
            let input = directory.appending(path: "archive.zip")
            try FileManager.default.copyItem(at: fixture(), to: input)
            let preview = try await service.open(input)
            try Data("replacement".utf8).write(to: input, options: .atomic)
            let task = service.extract(preview, to: directory)
            await #expect(throws: ArchiveError.changed) { try await task.value() }
            await #expect(throws: ArchiveError.changed) {
                try await service.readEntry(0, from: preview, maximumBytes: 100)
            }
        }
    }

    @Test(arguments: ["zipcrypto", "aes256"])
    func extractsPasswordProtectedZIP(_ name: String) async throws {
        try await temporaryDirectory { destination in
            let archive = try await service.open(fixture(name))
            let entry = try #require(archive.entries.first { $0.isEncrypted })
            #expect(archive.capabilities.contains(.encryption))
            #expect(entry.path == "private.txt")
            #expect(archive.entries.contains { $0.path == "public.txt" && !$0.isEncrypted })

            let missing = service.extract(archive, to: destination)
            await #expect(throws: ArchiveError.encrypted) { try await missing.value() }
            let wrong = service.extract(archive, to: destination,
                                        options: .init(passphrase: "wrong-password"))
            await #expect(throws: ArchiveError.incorrectPassphrase) { try await wrong.value() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

            let correct = service.extract(archive, to: destination,
                                          options: .init(passphrase: "fixture-pass"))
            try await correct.value()
            #expect(try String(contentsOf: destination.appending(path: "private.txt"), encoding: .utf8)
                    == "Protected document\n")
            #expect(try String(contentsOf: destination.appending(path: "public.txt"), encoding: .utf8)
                    == "Public document\n")
        }
    }

    @Test func opensAndExtractsStandaloneBrotli() async throws {
        try await temporaryDirectory { destination in
            let fixture = try #require(Bundle.module.url(forResource: "notes", withExtension: "br",
                                                         subdirectory: "Fixtures"))
            let archive = try await service.open(fixture)
            #expect(archive.format == .brotli)
            #expect(archive.isStream)
            #expect(archive.entries.map(\.path) == ["notes"])
            let task = service.extract(archive, to: destination)
            try await task.value()
            #expect(try String(contentsOf: destination.appending(path: "notes"), encoding: .utf8)
                    == "AetherUnzip fixture\n")
        }
    }

    @Test(arguments: [ArchiveFormat.zip, ArchiveFormat.sevenZip])
    func opensNumberedVolumes(_ format: ArchiveFormat) async throws {
        try await temporaryDirectory { destination in
            let name = format == .zip ? "sample.zip" : "sample.7z"
            let volumes = try ["001", "002", "003"].map { part in
                try #require(Bundle.module.url(forResource: name, withExtension: part,
                                               subdirectory: "Fixtures/Volumes"))
            }
            await #expect(throws: ArchiveError.missingVolume(2)) {
                try await service.open([volumes[0], volumes[2]])
            }
            await #expect(throws: ArchiveError.invalidVolumeSet) {
                try await service.open([volumes[0], volumes[0]])
            }
            let archive = try await service.open(Array(volumes.reversed()))
            #expect(archive.sourceURLs == volumes)
            #expect(archive.displayName == name)
            #expect(archive.format == format)
            #expect(archive.capabilities.contains(.multiVolume))
            #expect(archive.entries.map(\.path) == ["notes.txt"])
            let task = service.extract(archive, to: destination)
            try await task.value()
            #expect(try String(contentsOf: destination.appending(path: "notes.txt"), encoding: .utf8)
                    == "Known bytes for volume validation.\n")
        }
    }

    @Test func opensDiskZIP64AndRequiresTheFinalVolume() async throws {
        let volumes = try ["z01", "z02", "zip"].map { suffix in
            try independentFixture("small-disk64." + suffix)
        }
        await #expect(throws: ArchiveError.missingVolumeFile("small-disk64.zip")) {
            try await service.open(Array(volumes.dropLast()))
        }
        await #expect(throws: ArchiveError.missingVolumeFile("small-disk64.z01")) {
            try await service.open([volumes[2], volumes[1]])
        }
        let archive = try await service.open(Array(volumes.reversed()))
        #expect(archive.sourceURLs == volumes)
        #expect(archive.format == .zip)
        #expect(archive.entries.map(\.path) == ["first.txt", "second.txt"])
        try await temporaryDirectory { destination in
            try await service.extract(archive, to: destination).value()
            #expect(try String(contentsOf: destination.appending(path: "first.txt"), encoding: .utf8)
                    == "First ZIP64 disk\n")
            #expect(try String(contentsOf: destination.appending(path: "second.txt"), encoding: .utf8)
                    == "Second ZIP64 disk\n")
        }
    }

    @Test func opensAndExtractsIndependentRARVolumes() async throws {
        let numbered = try (1...4).map { try independentFixture("new.part0\($0).rar") }
        let archive = try await service.open(Array(numbered.reversed()))
        #expect(archive.format == .rar5)
        #expect(archive.capabilities.contains(.multiVolume))
        try await temporaryDirectory { destination in
            try await service.extract(archive, to: destination).value()
            let last = try Data(contentsOf: destination.appending(path: "elf-Linux-ARMv7-ls"))
            #expect(last.count == 90808)
            #expect(last.prefix(4) == Data([0x7f, 0x45, 0x4c, 0x46]))
        }

        try await temporaryDirectory { folder in
            let names = ["old.rar", "old.r00", "old.r01"]
            let legacy = try names.enumerated().map { index, name in
                let target = folder.appending(path: name)
                try FileManager.default.copyItem(at: independentFixture("old.part0\(index + 1).rar"),
                                                 to: target)
                return target
            }
            await #expect(throws: ArchiveError.missingVolumeFile("old.r00")) {
                try await service.open([legacy[2], legacy[0]])
            }
            let old = try await service.open(Array(legacy.reversed()))
            #expect(old.format == .rar)
            #expect(old.sourceURLs == legacy)
            try await temporaryDirectory { destination in
                try await service.extract(old, to: destination).value()
                let output = try Data(contentsOf: destination.appending(path: "LibarchiveAddingTest.html"))
                #expect(output.count == 20111)
                #expect(output.starts(with: "<!DOCTYPE HTML".utf8))
            }
        }
    }

    @Test func rejectsDamagedGZIPTrailerAndCleansTheOutput() async throws {
        let source = try #require(Bundle.module.url(forResource: "gzip-crc", withExtension: "gz",
                                                    subdirectory: "Fixtures"))
        let archive = try await service.open(source)
        #expect(archive.format == .gzip)
        try await temporaryDirectory { destination in
            let task = service.extract(archive, to: destination)
            await #expect(throws: ArchiveError.corrupt) { try await task.value() }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            #expect(remaining.isEmpty)
        }
    }

    @Test func recognizesAPrefixedZIPWithoutAnArchiveExtension() async throws {
        let source = try #require(Bundle.module.url(forResource: "prefixed-zip", withExtension: "bin",
                                                    subdirectory: "Fixtures"))
        let archive = try await service.open(source)
        #expect(archive.format == .zip)
        let notes = try #require(archive.entries.first { $0.path == "notes.txt" })
        try await temporaryDirectory { destination in
            try await service.extract(archive, to: destination, selecting: [notes.id]).value()
            #expect(try Data(contentsOf: destination.appending(path: "notes.txt")) ==
                    Data("AetherUnzip fixture\n".utf8))
        }
    }

    private func independentFixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil,
                                       subdirectory: "Fixtures/Independent"))
    }

    private func fixture(_ name: String = "sample") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures"))
    }

    private func temporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

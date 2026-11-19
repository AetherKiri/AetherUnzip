import CAetherUnzip
import Foundation

/// A fixed signature and a bounded payload range for a wrapped archive.
public struct FormatProfile: Codable, Equatable, Sendable {
    private static let formats: [String: ArchiveFormat] = [
        "zip": .zip, "tar": .tar, "7z": .sevenZip, "rar": .rar, "rar5": .rar5,
        "gzip": .gzip, "lz4": .lz4, "zstd": .zstandard, "xz": .xz, "bzip2": .bzip2,
        "cab": .cab, "iso9660": .iso9660, "lha": .lha, "brotli": .brotli, "xp3": .xp3
    ]
    public let version: Int
    public let signatureOffset: UInt64
    public let signatureHex: String
    public let payloadOffset: UInt64
    public let payloadLength: UInt64?
    public let payloadName: String?
    public let expectedFormat: ArchiveFormat

    let signature: [UInt8]

    public init(signatureHex: String, signatureOffset: UInt64 = 0, payloadOffset: UInt64,
                payloadLength: UInt64? = nil, payloadName: String? = nil,
                expectedFormat: ArchiveFormat) throws {
        guard !signatureHex.isEmpty, signatureHex.utf8.count <= Int(AU_PROFILE_MAX_SIGNATURE) * 2,
              signatureHex.utf8.count.isMultiple(of: 2), expectedFormat != .unknown,
              payloadLength != 0 else { throw ArchiveError.invalidProfile }
        let hex = Array(signatureHex.utf8)
        var signature: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = Self.nibble(hex[index]), let low = Self.nibble(hex[index + 1]) else {
                throw ArchiveError.invalidProfile
            }
            signature.append(high << 4 | low)
        }
        if let payloadName {
            guard !payloadName.isEmpty, payloadName != ".", payloadName != "..",
                  payloadName.utf8.count <= 255,
                  !payloadName.utf8.contains(where: { $0 < 32 || $0 == 47 || $0 == 58 || $0 == 92 }) else {
                throw ArchiveError.invalidProfile
            }
        }
        if expectedFormat == .brotli && payloadName?.lowercased().hasSuffix(".br") != true {
            throw ArchiveError.invalidProfile
        }
        version = 1
        self.signatureOffset = signatureOffset
        self.signatureHex = signatureHex.lowercased()
        self.payloadOffset = payloadOffset
        self.payloadLength = payloadLength
        self.payloadName = payloadName
        self.expectedFormat = expectedFormat
        self.signature = signature
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, signatureOffset, signatureHex, payloadOffset, payloadLength, payloadName, expectedFormat
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1,
              let format = Self.formats[try values.decode(String.self, forKey: .expectedFormat)] else {
            throw ArchiveError.invalidProfile
        }
        try self.init(signatureHex: values.decode(String.self, forKey: .signatureHex),
                      signatureOffset: values.decodeIfPresent(UInt64.self, forKey: .signatureOffset) ?? 0,
                      payloadOffset: values.decode(UInt64.self, forKey: .payloadOffset),
                      payloadLength: values.decodeIfPresent(UInt64.self, forKey: .payloadLength),
                      payloadName: values.decodeIfPresent(String.self, forKey: .payloadName),
                      expectedFormat: format)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        guard let format = Self.formats.first(where: { $0.value == expectedFormat })?.key else {
            throw ArchiveError.invalidProfile
        }
        try values.encode(version, forKey: .version)
        try values.encode(signatureOffset, forKey: .signatureOffset)
        try values.encode(signatureHex, forKey: .signatureHex)
        try values.encode(payloadOffset, forKey: .payloadOffset)
        try values.encodeIfPresent(payloadLength, forKey: .payloadLength)
        try values.encodeIfPresent(payloadName, forKey: .payloadName)
        try values.encode(format, forKey: .expectedFormat)
    }

    func withCore<T>(name: String, _ body: (inout au_format_profile) throws -> T) rethrows -> T {
        try (payloadName ?? name).withCString { name in
            try signature.withUnsafeBytes { bytes in
                var profile = au_format_profile(struct_size: UInt32(MemoryLayout<au_format_profile>.size),
                    format: expectedFormat.rawValue, signature_offset: signatureOffset,
                    signature: bytes.baseAddress, signature_size: bytes.count,
                    payload_offset: payloadOffset, payload_size: payloadLength ?? 0, name_hint: name)
                return try body(&profile)
            }
        }
    }
}

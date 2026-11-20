import AetherUnzipKit
import Foundation
import Security

enum PasswordChoice: Sendable {
    case automatic
    case manual(String, remember: Bool)
    case saved(UUID, remember: Bool)
    case library(remember: Bool)
}

struct PasswordLabel: Codable, Identifiable, Sendable {
    let id: UUID
    let title: String
}

struct PasswordCandidate: Sendable, CustomReflectable {
    let value: String
    let remember: Bool

    var customMirror: Mirror { Mirror(self, unlabeledChildren: EmptyCollection<Any>()) }
}

actor PasswordLibrary {
    private struct Entry: Codable {
        let label: PasswordLabel
        let password: String
    }

    private struct Contents: Codable {
        var entries: [Entry] = []
        var remembered: [String: UUID] = [:]
    }

    enum Failure: LocalizedError {
        case unavailable, removed, empty, invalid

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "The password library could not be accessed.")
            case .removed: String(localized: "This password is no longer in the library.")
            case .empty: String(localized: "The password library is empty.")
            case .invalid: String(localized: "Enter a valid password.")
            }
        }
    }

    private var query: [String: Any] {
        var service = "org.aetherunzip.app.archive-passwords.v1"
        #if DEBUG && targetEnvironment(simulator)
        if let namespace = UserDefaults.standard.string(forKey: "PasswordLibraryTestNamespace") {
            service += "." + namespace
        }
        #endif
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "library",
            kSecAttrSynchronizable as String: false
        ]
    }

    func labels() throws -> [PasswordLabel] { try load().entries.map(\.label) }

    func hasArchiveAssociations() throws -> Bool { try !load().remembered.isEmpty }

    func rememberedID(for fingerprint: String) throws -> UUID? { try load().remembered[fingerprint] }

    func candidates(for choice: PasswordChoice) throws -> [PasswordCandidate] {
        switch choice {
        case .automatic: []
        case .manual(let password, let remember): [.init(value: password, remember: remember)]
        case .saved(let id, let remember):
            if let entry = try load().entries.first(where: { $0.label.id == id }) {
                [.init(value: entry.password, remember: remember)]
            } else {
                throw Failure.removed
            }
        case .library(let remember):
            try allCandidates(remember: remember)
        }
    }

    private func allCandidates(remember: Bool) throws -> [PasswordCandidate] {
        let entries = try load().entries
        guard !entries.isEmpty else { throw Failure.empty }
        return entries.map { PasswordCandidate(value: $0.password, remember: remember) }
    }

    @discardableResult
    func save(_ password: String, title: String, fingerprint: String? = nil) throws -> PasswordLabel {
        guard !password.isEmpty, !password.utf8.contains(0) else { throw Failure.invalid }
        var contents = try load()
        let entry: Entry
        if let index = contents.entries.firstIndex(where: { $0.password.utf8.elementsEqual(password.utf8) }) {
            entry = contents.entries.remove(at: index)
        } else {
            let names = Set(contents.entries.map(\.label.title))
            var unique = title
            var suffix = 2
            while names.contains(unique) {
                unique = "\(title) (\(suffix))"
                suffix += 1
            }
            entry = Entry(label: PasswordLabel(id: UUID(), title: unique), password: password)
        }
        contents.entries.insert(entry, at: 0)
        if let fingerprint { contents.remembered[fingerprint] = entry.label.id }
        try store(contents)
        return entry.label
    }

    func remove(_ id: UUID) throws {
        var contents = try load()
        contents.entries.removeAll { $0.label.id == id }
        contents.remembered = contents.remembered.filter { $0.value != id }
        if contents.entries.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
        } else {
            try store(contents)
        }
    }

    private func load() throws -> Contents {
        var selection = query
        selection[kSecReturnData as String] = true
        selection[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(selection as CFDictionary, &result)
        if status == errSecItemNotFound { return Contents() }
        guard status == errSecSuccess, let data = result as? Data,
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { throw Failure.unavailable }
        return contents
    }

    private func store(_ contents: Contents) throws {
        let data = try JSONEncoder().encode(contents)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            #if os(iOS)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #endif
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
        } else if status != errSecSuccess {
            throw Failure.unavailable
        }
    }
}

extension ArchiveError {
    var needsArchivePassword: Bool { self == .encrypted || self == .incorrectPassphrase }
}

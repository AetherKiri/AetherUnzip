import SwiftUI

struct PasswordLibraryView: View {
    let library: PasswordLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PasswordLabel] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var deleting: PasswordLabel?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if entries.isEmpty {
                    ContentUnavailableView("No Saved Passwords", systemImage: "key",
                                           description: Text("Save archive passwords to choose them again later."))
                } else {
                    List(entries) { entry in
                        Label(entry.title, systemImage: "key")
                            .accessibilityIdentifier("password-library-entry")
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
                            }
                    }
                    .modifier(WorkspaceListSurface())
                }
            }
            .navigationTitle("Password Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Password", systemImage: "plus") { adding = true }
                        .accessibilityIdentifier("password-library-add")
                }
            }
            .task {
                do { entries = try await library.labels() }
                catch { self.error = error.localizedDescription }
                loaded = true
            }
            .sheet(isPresented: $adding) {
                AddArchivePassword(library: library) { entries = $0 }
            }
            .confirmationDialog("Delete Saved Password?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { entry in
                Button("Delete", role: .destructive) { remove(entry) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Archives that use this password will ask for it again.")
            }
            .alert("Password Library", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }

    private func remove(_ entry: PasswordLabel) {
        Task {
            do {
                try await library.remove(entry.id)
                entries = try await library.labels()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct AddArchivePassword: View {
    let library: PasswordLibrary
    let saved: ([PasswordLabel]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: String(localized: "Add Password"), symbol: "key", singleLine: true)
            Text("Name").font(.subheadline.weight(.medium))
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .modifier(WorkspaceInputWell(focused: nameFocused))
                .accessibilityIdentifier("password-library-name")
            WorkspacePasswordField(title: "Password", password: $password,
                                   identifier: "password-library-value", submit: save)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .modifier(WorkspaceButton(prominent: true))
                    .disabled(!canSave)
                    .accessibilityIdentifier("password-library-save")
            }
        }
        .padding(24)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
    }

    private var canSave: Bool {
        !saving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func save() {
        guard canSave else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await library.save(password, title: name.trimmingCharacters(in: .whitespacesAndNewlines))
                password = ""
                saved(try await library.labels())
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

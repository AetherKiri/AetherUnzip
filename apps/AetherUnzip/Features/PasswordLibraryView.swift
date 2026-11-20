import SwiftUI

struct PasswordLibraryView: View {
    let library: PasswordLibrary
    let refreshVersion: Int
    @State private var entries: [PasswordLabel] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var deleting: PasswordLabel?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            passwords
        }
        .modifier(WorkspaceCanvas())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: refreshVersion) {
            do {
                let labels = try await library.labels()
                guard !Task.isCancelled else { return }
                entries = labels
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
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

    private var header: some View {
        HStack(spacing: 8) {
            WorkspaceHeading(title: String(localized: "Password Library"))
            Button { adding = true } label: {
                Label("Add Password", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.accentColor)
            }
            .modifier(WorkspaceButton())
            .help("Add Password")
            .accessibilityIdentifier("password-library-add")
        }
        .modifier(WorkspaceHeaderLayout())
    }

    @ViewBuilder private var passwords: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView("No Saved Passwords", systemImage: "key",
                                   description: Text("Save archive passwords to choose them again later."))
        } else {
            List(entries) { entry in
                HStack(spacing: 10) {
                    WorkspaceGlyph(symbol: "key", tint: .accentColor)
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
                }
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
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

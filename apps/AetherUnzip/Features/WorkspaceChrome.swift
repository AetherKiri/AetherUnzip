import SwiftUI

enum WorkspacePalette {
    static let accent = Color(red: 0.12, green: 0.35, blue: 0.67)
    static let archive = Color.teal
}

enum WorkspaceMotion {
    static let feedback = Animation.smooth(duration: 0.18)
    static let layout = Animation.smooth(duration: 0.26)

    static var bottomInset: AnyTransition { .offset(y: 8).combined(with: .opacity) }
}

struct WorkspaceAccent: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let accent = scheme == .dark ? Color(red: 0.58, green: 0.74, blue: 0.96) : WorkspacePalette.accent
        return content.accentColor(accent).tint(accent)
    }
}

struct WorkspaceCanvas: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        #else
        content.background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        #endif
    }
}

struct WorkspaceListSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .listStyle(.insetGrouped)
            .listSectionSpacing(10)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
        #else
        content
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        #endif
    }
}

struct WorkspaceGlyph: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

struct WorkspaceSelectionMark: View {
    let selected: Bool
    var unselectedTint: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.accentColor : unselectedTint)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: selected)
    }
}

struct WorkspaceDisplayTitle: View {
    let title: String
    var compact = false

    var body: some View {
        Text(title)
            .font(compact ? .title2.weight(.semibold) : .largeTitle.weight(.semibold))
            .tracking(compact ? -0.35 : -0.9)
            .lineLimit(compact ? 1 : 2)
            .minimumScaleFactor(compact ? 0.82 : 0.94)
            .truncationMode(.middle)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WorkspaceHeading: View {
    let title: String
    var symbol: String?
    var tint: Color = .accentColor
    var detail: String?
    var singleLine = false

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                WorkspaceGlyph(symbol: symbol, tint: tint, size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                WorkspaceDisplayTitle(title: title, compact: singleLine)
                if let detail {
                    Text(detail)
                        .font(singleLine ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkspaceHeaderLayout: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
    }
}

struct WorkspaceButton: ViewModifier {
    var prominent = false

    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(WorkspacePalette.accent)
        } else {
            content.buttonStyle(ToolbarActionStyle())
        }
    }

    private struct ToolbarActionStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            #if os(iOS)
            let target: CGFloat = 44
            #else
            let target: CGFloat = 32
            #endif
            let pressed = isEnabled && configuration.isPressed
            return configuration.label
                .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                .opacity(isEnabled ? (pressed ? 0.68 : 1) : 0.48)
                .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: pressed)
                .frame(minWidth: target, minHeight: target)
                .contentShape(Rectangle())
        }
    }
}

struct WorkspaceInputWell: ViewModifier {
    let focused: Bool
    var invalid = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(invalid ? Color.red.opacity(0.7) : (focused ? Color.accentColor.opacity(0.65) : .clear),
                                  lineWidth: 1)
                    .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: focused)
                    .animation(reduceMotion ? nil : WorkspaceMotion.feedback, value: invalid)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkspaceSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let identifier: String
    let clearIdentifier: String

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                Button { focus.wrappedValue = true } label: {
                    Label("Focus Search", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                TextField(prompt, text: $text, prompt: Text(prompt).foregroundColor(.secondary))
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .accessibilityIdentifier(identifier)
                    #if os(iOS)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #else
                    .onExitCommand { focus.wrappedValue = false }
                    #endif
                    .onSubmit { focus.wrappedValue = false }
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Label("Clear Search", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 30, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(clearIdentifier)
                }
            }
            .modifier(WorkspaceInputWell(focused: focus.wrappedValue))
            if focus.wrappedValue {
                Button("Done") { focus.wrappedValue = false }
                    .fontWeight(.semibold)
                    .modifier(WorkspaceButton())
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("\(identifier)-done")
            }
        }
        .font(.subheadline)
    }
}

struct WorkspacePasswordField: View {
    private enum Mode: Hashable { case masked, visible }

    let title: LocalizedStringKey
    @Binding var password: String
    let identifier: String
    var autoFocus = false
    var invalid = false
    var submit: () -> Void = {}
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focus: Mode?
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                Group {
                    if isVisible {
                        TextField(title, text: $password).focused($focus, equals: .visible)
                    } else {
                        SecureField(title, text: $password).focused($focus, equals: .masked)
                    }
                }
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .onSubmit(submit)
                .accessibilityIdentifier(identifier)
                Button {
                    let wasFocused = focus != nil
                    isVisible.toggle()
                    if wasFocused { focus = isVisible ? .visible : .masked }
                } label: {
                    Label(isVisible ? "Hide Password" : "Show Password", systemImage: isVisible ? "eye.slash" : "eye")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier)-visibility")
            }
            .modifier(WorkspaceInputWell(focused: focus != nil, invalid: invalid))
        }
        .onAppear { focusIfNeeded() }
        .onChange(of: isEnabled) {
            if isEnabled { focusIfNeeded() }
            else { focus = nil }
        }
    }

    private func focusIfNeeded() {
        if autoFocus && isEnabled { focus = isVisible ? .visible : .masked }
    }
}

import AinkradAppKit
import SwiftUI

struct ConnectionEditorView: View {
    @Bindable var store: LeylineStore
    let theme: HostTheme
    let existing: LeylineConnection?
    let onClose: () -> Void

    @Environment(\.ainkradTypography) private var typo
    @State private var label = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMode: LeylineConnection.AuthMode = .password
    @State private var password = ""
    @State private var keyID: UUID?

    private var t: HostThemeTokens { theme.tokens }
    private var portValue: Int? { PortField.parse(port) }

    /// `AinkradSelect` needs a `Hashable` selection with no associated
    /// optionality — wraps `keyID: UUID?` (`.none` is a real, selectable
    /// option: "no key").
    private enum KeyChoice: Hashable {
        case none
        case key(UUID)
    }
    private var keyChoiceBinding: Binding<KeyChoice> {
        Binding(
            get: { keyID.map(KeyChoice.key) ?? .none },
            set: { newValue in
                switch newValue {
                case .none: keyID = nil
                case .key(let id): keyID = id
                }
            }
        )
    }
    private var keyChoices: [KeyChoice] { [.none] + store.keys.map { .key($0.id) } }
    private func keyChoiceLabel(_ choice: KeyChoice) -> String {
        switch choice {
        case .none: return "None"
        case .key(let id): return store.keys.first(where: { $0.id == id })?.label ?? "Unknown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Connection" : "Edit Connection")
                .font(AinkradFontResolver.font(.headline, weight: .semibold, typography: typo))
                .foregroundStyle(t.foreground)

            AinkradFormRow(title: "Label") {
                AinkradTextField(text: $label, placeholder: "Prod Web")
            }
            HStack(alignment: .bottom, spacing: 10) {
                AinkradFormRow(title: "Host") {
                    AinkradTextField(text: $host, placeholder: "example.com")
                }
                AinkradFormRow(title: "Port") {
                    AinkradTextField(text: $port, placeholder: "22")
                }.frame(width: 110)
            }
            if portValue == nil {
                HStack(spacing: AinkradSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").font(
                        AinkradFontResolver.font(.caption, typography: typo))
                    Text(PortField.errorMessage).font(AinkradFontResolver.font(.caption, typography: typo))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(t.accentTertiary)
            }
            AinkradFormRow(title: "Username") {
                AinkradTextField(text: $username, placeholder: "deploy")
            }

            AinkradFormRow(title: "Auth") {
                AinkradSegmentedPicker(items: [LeylineConnection.AuthMode.password, .key], selection: $authMode) {
                    $0 == .password ? "Password" : "Key"
                }
            }

            if authMode == .password {
                AinkradFormRow(title: "Password") {
                    AinkradSecureField(text: $password, placeholder: "")
                }
            } else {
                AinkradFormRow(title: "Key") {
                    AinkradSelect(items: keyChoices, selection: keyChoiceBinding, label: keyChoiceLabel)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost) { onClose() }.keyboardShortcut(.cancelAction)
                AinkradButton(title: "Save", style: .primary, icon: "checkmark") { save() }
                    .disabled(host.isEmpty || portValue == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 400)
        .background(LeylineHUD.sheetBackground(t))
        .foregroundStyle(t.foreground)
        .onAppear(perform: load)
    }

    private func load() {
        guard let c = existing else { return }
        label = c.label
        host = c.host
        port = String(c.port)
        username = c.username
        authMode = c.authMode
        keyID = c.keyID
        if c.authMode == .password { password = store.password(for: c) ?? "" }
    }

    private func save() {
        guard let portValue else { return }
        if var c = existing {
            c.label = label
            c.host = host
            c.port = portValue
            c.username = username
            c.authMode = authMode
            c.keyID = authMode == .key ? keyID : nil
            store.updateConnection(c)
            store.setPassword(authMode == .password ? password : nil, for: c)
        } else {
            store.addConnection(
                label: label, host: host, port: portValue, username: username,
                authMode: authMode, keyID: authMode == .key ? keyID : nil,
                password: authMode == .password ? password : nil)
        }
        onClose()
    }
}

import AinkradAppKit
import SwiftUI

struct KeyVaultView: View {
    @Bindable var store: LeylineStore
    let theme: HostTheme
    let onClose: () -> Void

    @Environment(\.ainkradTypography) private var typo
    @State private var showingPaste = false
    @State private var pasteLabel = ""
    @State private var pasteBody = ""
    @State private var pastePassphrase = ""
    @State private var hovered: UUID?
    @State private var importError: String?

    private var t: HostThemeTokens { theme.tokens }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SSH Keys")
                    .font(AinkradFontResolver.font(.headline, weight: .semibold, typography: typo))
                    .foregroundStyle(t.foreground)
                Spacer()
                AinkradButton(title: "Import File", style: .secondary, icon: "folder") { presentImportPanel() }
                AinkradButton(title: "Paste", style: .secondary, icon: "doc.on.clipboard") { showingPaste = true }
            }
            LeylineHUD.glowRule(t)

            if let importError {
                HStack(spacing: AinkradSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").font(
                        AinkradFontResolver.font(.caption, typography: typo))
                    Text(importError).font(AinkradFontResolver.font(.caption, typography: typo)).fixedSize(
                        horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    AinkradIconButton(systemName: "xmark", size: 18) { self.importError = nil }
                }
                .foregroundStyle(t.accentTertiary)
            }

            if store.keys.isEmpty {
                emptyKeys
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.keys) { key in keyRow(key) }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                AinkradButton(title: "Done", style: .primary) { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 380)
        .background(LeylineHUD.sheetBackground(t))
        .foregroundStyle(t.foreground)
        .ainkradModal(isPresented: $showingPaste) { pasteModalContent }
    }

    @ViewBuilder private func keyRow(_ key: LeylineKey) -> some View {
        let isHover = hovered == key.id
        AinkradListRow(
            isSelected: isHover,
            leading: {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.accentTertiary)
                    .frame(width: 24, height: 24)
                    .background(ChamferShape(cut: AinkradRadius.sm).fill(t.accentTertiary.opacity(0.14)))
                    .overlay(
                        ChamferShape(cut: AinkradRadius.sm).strokeBorder(t.accentTertiary.opacity(0.3), lineWidth: 0.5))
            },
            title: key.label,
            subtitle: key.hasPassphrase ? "Passphrase-protected" : nil,
            trailing: {
                AinkradIconButton(systemName: "trash") { store.removeKey(key) }
                    .help("Delete key")
                    .opacity(isHover ? 1 : 0)
                    .allowsHitTesting(isHover)
            }
        )
        .onHover { h in hovered = h ? key.id : nil }
    }

    private var emptyKeys: some View {
        AinkradEmptyState(
            icon: "key",
            title: "No keys imported",
            message: "Import a private key by file or paste"
        )
    }

    private var pasteModalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Private Key")
                .font(AinkradFontResolver.font(.headline, weight: .semibold, typography: typo))
                .foregroundStyle(t.foreground)
            AinkradFormRow(title: "Label") {
                AinkradTextField(text: $pasteLabel, placeholder: "id_ed25519")
            }
            AinkradFormRow(title: "Private Key") {
                AinkradTextArea(text: $pasteBody, placeholder: "-----BEGIN OPENSSH PRIVATE KEY-----")
            }
            AinkradFormRow(title: "Passphrase (optional)") {
                AinkradSecureField(text: $pastePassphrase, placeholder: "")
            }
            HStack(spacing: 10) {
                Spacer()
                AinkradButton(title: "Cancel", style: .ghost) { showingPaste = false }.keyboardShortcut(.cancelAction)
                AinkradButton(title: "Import", style: .primary, icon: "checkmark") { importPasted() }
                    .disabled(pasteBody.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
        .foregroundStyle(t.foreground)
    }

    private func importPasted() {
        store.importKey(
            label: pasteLabel.isEmpty ? "Imported Key" : pasteLabel,
            privateKey: pasteBody,
            passphrase: pastePassphrase.isEmpty ? nil : pastePassphrase)
        pasteLabel = ""
        pasteBody = ""
        pastePassphrase = ""
        showingPaste = false
    }

    /// Uses `NSOpenPanel` (not SwiftUI's `.fileImporter`) so hidden files are
    /// shown by default — SSH keys live in `~/.ssh`, a dotfile directory the
    /// stock importer hides. The panel selection also grants read access.
    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose an SSH private key"
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url { importFile(url) }
    }

    private func importFile(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        switch KeyImportFile.read(url) {
        case .success(let body):
            importError = nil
            store.importKey(label: url.lastPathComponent, privateKey: body, passphrase: nil)
        case .failure(let e):
            importError = e.message
        }
    }
}

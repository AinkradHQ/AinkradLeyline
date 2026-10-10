import AinkradAppKit
import SwiftUI

struct LeylineRootView: View {
    @Bindable var store: LeylineStore
    let theme: HostTheme
    let launcher: PluginAppLauncher

    @State private var query = ""
    @State private var editing: LeylineConnection?
    @State private var showingNew = false
    @State private var showingKeys = false
    @State private var copied: UUID?
    @State private var hovered: UUID?
    /// Non-nil when the last connect attempt failed. Surfaces what used to be
    /// discarded: `apps.open` returned Void, so a missing or disabled Rune
    /// looked exactly like a successful launch.
    @State private var launchError: String?
    @Environment(\.ainkradSkin) private var skin

    private var t: HostThemeTokens { theme.tokens }
    private var filtered: [LeylineConnection] { ConnectionFilter.matching(query, in: store.connections) }

    var body: some View {
        VStack(spacing: 0) {
            header
            AinkradSearchField(text: $query, placeholder: "Search connections")
                .padding(.horizontal, skin.size.s14)
                .padding(.bottom, skin.size.s10)
            if let launchError {
                AinkradBanner(message: launchError, status: .warning, onDismiss: { self.launchError = nil })
                    .padding(.horizontal, skin.size.s14).padding(.top, AinkradSpacing.sm)
            }
            content
        }
        // In-surface HUD overlays (chamfer + dim + scrim/Esc dismiss), scoped
        // to this root view — never a native `.sheet`. The `editing` modal is
        // driven by the item's presence; `editing` itself stays available to
        // the hosted content for the duration the modal is up.
        .ainkradModal(isPresented: $showingNew) {
            ConnectionEditorView(store: store, theme: theme, existing: nil, onClose: { showingNew = false })
        }
        .ainkradModal(
            isPresented: Binding(
                get: { editing != nil },
                set: { isPresented in if !isPresented { editing = nil } }
            )
        ) {
            if let editing {
                ConnectionEditorView(store: store, theme: theme, existing: editing, onClose: { self.editing = nil })
            }
        }
        .ainkradModal(isPresented: $showingKeys) {
            KeyVaultView(store: store, theme: theme, onClose: { showingKeys = false })
        }
    }

    // MARK: Header (wordmark + HUD actions)

    private var header: some View {
        HStack(spacing: skin.size.s10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(skin.font(AinkradFontToken(sizeKey: "t15", weight: "semibold")))
                .foregroundStyle(t.accentSecondary)
                // Liquid Glass draws no glows.
                .shadow(color: skin.usesNativeGlass ? .clear : t.accentSecondary.opacity(skin.opacity.o50), radius: skin.size.s5)
            Text(skin.labelCased("Leyline"))
                .font(skin.font(AinkradFontToken(sizeKey: "t12", weight: "bold", mono: "system")))
                .kerning(skin.type.labelCase == "none" ? 0 : 3)
                .foregroundStyle(t.foreground.opacity(skin.opacity.o85))
            Spacer()
            AinkradIconButton(systemName: "key.fill", tooltip: "SSH Keys") { showingKeys = true }
            AinkradIconButton(systemName: "plus", tooltip: "New Connection") { showingNew = true }
        }
        .padding(.horizontal, skin.size.s14)
        .padding(.top, skin.size.s14)
        .padding(.bottom, AinkradSpacing.md)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: skin.size.s2) {
                    ForEach(filtered) { conn in row(conn) }
                }
                .padding(.horizontal, AinkradSpacing.sm)
                .padding(.vertical, skin.size.s10)
            }
        }
    }

    private var emptyState: some View {
        AinkradEmptyState(
            icon: store.connections.isEmpty ? "point.3.connected.trianglepath.dotted" : "magnifyingglass",
            title: store.connections.isEmpty ? "No connections yet" : "No matches",
            message: store.connections.isEmpty ? "Add a host with  +" : "Try a different search"
        )
    }

    // MARK: Row

    @ViewBuilder private func row(_ conn: LeylineConnection) -> some View {
        let isHover = hovered == conn.id
        let authColor = conn.authMode == .key ? t.accentTertiary : t.accentSecondary
        AinkradListRow(
            // Neon lights the hovered row; under Liquid Glass "selected" is the
            // solid accent fill, so hover is left to the row's own quiet fill.
            isSelected: isHover && !skin.usesNativeGlass,
            leading: {
                Image(systemName: conn.authMode == .key ? "key.fill" : "lock.fill")  // auth badge
                    .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "semibold")))
                    .foregroundStyle(authColor)
                    .frame(width: skin.size.s24, height: skin.size.s24)
                    .background(skin.shape(cut: AinkradRadius.sm).fill(authColor.opacity(skin.opacity.o14)))
                    .overlay(
                        // Liquid Glass: a tinted tile, no outline.
                        skin.shape(cut: AinkradRadius.sm).strokeBorder(
                            skin.usesNativeGlass ? .clear : authColor.opacity(skin.opacity.o30), lineWidth: 0.5))
            },
            title: conn.label.isEmpty ? conn.host : conn.label,
            subtitle: SSHCommand.string(for: conn),
            trailing: {
                HStack(spacing: skin.size.s6) {
                    HStack(spacing: skin.size.s6) {  // hover-revealed secondary actions
                        AinkradIconButton(
                            systemName: copied == conn.id ? "checkmark" : "doc.on.doc", tooltip: "Copy ssh command"
                        ) {
                            copyCommand(conn)
                        }
                        AinkradIconButton(systemName: "pencil", tooltip: "Edit") { editing = conn }
                        AinkradIconButton(systemName: "trash", tooltip: "Delete") { store.removeConnection(conn) }
                    }
                    .opacity(isHover ? 1 : 0)
                    .allowsHitTesting(isHover)

                    // Always-visible primary action.
                    AinkradButton(title: "Connect", style: .primary, icon: "bolt.fill") { connect(conn) }
                }
            }
        )
        .onHover { h in hovered = h ? conn.id : nil }
    }

    // MARK: Actions

    private func copyCommand(_ conn: LeylineConnection) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SSHCommand.string(for: conn), forType: .string)
        copied = conn.id
    }

    /// Delegates to `LeylineConnectAction` so advanced and basic share ONE
    /// implementation — see that type for why a second copy is a bug waiting.
    private func connect(_ conn: LeylineConnection) {
        launchError = LeylineConnectAction.connect(conn, store: store, launcher: launcher)
    }
}

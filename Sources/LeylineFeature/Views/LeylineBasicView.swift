import AinkradAppKit
import SwiftUI

/// Leyline's **basic** mode: pick a connection, connect. Nothing else.
///
/// The one thing Leyline is opened for, most of the time, is reaching a host.
/// Everything that manages connections rather than uses them — the editor, the
/// key vault, delete, copy-the-ssh-command — stays in advanced, and none of it
/// is constructed here.
///
/// Search is present rather than trimmed away because it is not a feature here:
/// with more than a handful of hosts it IS how you pick the target, so removing
/// it would make the fast path slower.
///
/// Connect is deliberately the SAME code path as advanced
/// (`LeylineConnectAction`), not a second copy. Two implementations of "make
/// this connection's key readable by ssh" is exactly the split that once sent
/// the agent path out without a key and gave users `Permission denied`.
struct LeylineBasicView: View {
    @Bindable var store: LeylineStore
    let theme: HostTheme
    let launcher: PluginAppLauncher

    @State private var query = ""
    @State private var launchError: String?
    @Environment(\.ainkradSkin) private var skin

    private var t: HostThemeTokens { theme.tokens }
    private var filtered: [LeylineConnection] { ConnectionFilter.matching(query, in: store.connections) }

    var body: some View {
        AinkradBasicShell(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Leyline",
            subtitle: subtitle
        ) {
            VStack(spacing: AinkradSpacing.sm) {
                if store.connections.count > 5 {
                    AinkradSearchField(text: $query, placeholder: "Search connections")
                }
                if let launchError {
                    AinkradBanner(message: launchError, status: .warning, onDismiss: { self.launchError = nil })
                }
                content
            }
        }
    }

    private var subtitle: String {
        let n = store.connections.count
        return n == 1 ? "1 connection" : "\(n) connections"
    }

    @ViewBuilder private var content: some View {
        if filtered.isEmpty {
            AinkradEmptyState(
                icon: store.connections.isEmpty ? "point.3.connected.trianglepath.dotted" : "magnifyingglass",
                title: store.connections.isEmpty ? "No connections yet" : "No matches",
                message: store.connections.isEmpty
                    ? "Add one in advanced mode."
                    : "Try a different search")
        } else {
            ScrollView {
                VStack(spacing: skin.size.s2) {
                    ForEach(filtered) { conn in row(conn) }
                }
            }
        }
    }

    /// No hover-revealed edit/delete/copy — those manage a connection rather
    /// than use one, and a destructive action one hover away is not what a
    /// stripped-down mode is for.
    private func row(_ conn: LeylineConnection) -> some View {
        AinkradListRow(
            isSelected: false,
            leading: {
                Image(systemName: conn.authMode == .key ? "key.fill" : "lock.fill")
                    .font(skin.font(AinkradFontToken(sizeKey: "t11", weight: "semibold")))
                    .foregroundStyle(conn.authMode == .key ? t.accentTertiary : t.accentSecondary)
                    .frame(width: skin.size.s24, height: skin.size.s24)
            },
            title: conn.label.isEmpty ? conn.host : conn.label,
            subtitle: SSHCommand.string(for: conn),
            trailing: {
                AinkradButton(title: "Connect", style: .primary, icon: "bolt.fill") {
                    launchError = LeylineConnectAction.connect(conn, store: store, launcher: launcher)
                }
            }
        )
    }
}

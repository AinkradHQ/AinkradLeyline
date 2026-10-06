import AinkradAppKit
import Foundation

/// "Open this connection in Rune" — one implementation, shared by advanced
/// mode, basic mode, and anything added later.
///
/// Extracted when basic mode arrived, for the reason this code already learned
/// once: while the key resolution lived inside the view, the agent-initiated
/// path had to either duplicate it or go without a key, and it went without —
/// users got `Permission denied`. A second copy for basic mode would have been
/// the same mistake with a different caller.
///
/// Returns the message to show, or `nil` on success, so the caller owns its own
/// error presentation without this needing to know about either view.
@MainActor
enum LeylineConnectAction {
    static func connect(
        _ conn: LeylineConnection,
        store: LeylineStore,
        launcher: PluginAppLauncher
    ) -> String? {
        let identityFile = SSHIdentityResolver.resolve(conn, store: store).path
        let payload = SSHLaunchPayload(
            host: conn.host, port: conn.port, username: conn.username, identityFile: identityFile
        )
        // Validate before sending. Every field lands in an `ssh` argv, and
        // `ssh`'s option surface (`-o ProxyCommand=…`) runs shell commands — so
        // a hostile hostname or username is code execution. Refusing here means
        // the malformed connection never leaves this process.
        guard let safe = try? payload.validated() else {
            return "This connection has an unsafe host, username or key path."
        }
        // Report the outcome instead of discarding it. `open(appID:payload:)`
        // returns Void, so the button looked identical whether Rune opened or
        // was not installed at all.
        switch launch(safe, with: launcher) {
        case .opened: return nil
        case .unknownApp: return "Rune isn't installed — install it from the App Store."
        case .disabled: return "Rune is disabled — enable it in the App Store."
        case .refused(let why): return "Couldn't open Rune: \(why)"
        // `PluginLaunchOutcome` lives in a resilient module, so the compiler
        // requires a default: a newer SDK may add a case this build has never
        // seen. Treat anything unknown as a failure rather than as success.
        @unknown default: return "Couldn't open Rune."
        }
    }

    /// Hands a validated launch to Rune and reports what happened — the one
    /// launch both the Connect buttons and the MCP `connect` tool use.
    /// `openReportingOutcome` is the opt-in richer launcher, found by dynamic
    /// cast. On a host that predates it, fall back to the Void-returning `open`,
    /// which cannot tell success from a missing Rune, so it reports `.opened`.
    static func launch(_ payload: SSHLaunchPayload, with launcher: PluginAppLauncher) -> PluginLaunchOutcome {
        if let reporting = launcher as? PluginAppLauncherResult {
            return reporting.openReportingOutcome(appID: "rune", payload: payload.json)
        }
        launcher.open(appID: "rune", payload: payload.json)
        return .opened
    }
}

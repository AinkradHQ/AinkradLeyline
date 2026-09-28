import Foundation
import AinkradAppKit

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
    static func connect(_ conn: LeylineConnection,
                        store: LeylineStore,
                        launcher: PluginAppLauncher) -> String? {
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
        let outcome = (launcher as? PluginAppLauncherResult)?
            .openReportingOutcome(appID: "rune", payload: safe.json)
            ?? { launcher.open(appID: "rune", payload: safe.json); return .opened }()
        switch outcome {
        case .opened:            return nil
        case .unknownApp:        return "Rune isn't installed — install it from the App Store."
        case .disabled:          return "Rune is disabled — enable it in the App Store."
        case .refused(let why):  return "Couldn't open Rune: \(why)"
        // `PluginLaunchOutcome` lives in a resilient module, so the compiler
        // requires a default: a newer SDK may add a case this build has never
        // seen. Treat anything unknown as a failure rather than as success.
        @unknown default:        return "Couldn't open Rune."
        }
    }
}

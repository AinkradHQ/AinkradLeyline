import AinkradAppKit
import Foundation

/// The ONLY view of Leyline's data that the MCP layer is given.
///
/// ## Why this type exists at all
///
/// This is the single most important line of defence in the MCP work, and it is
/// structural rather than procedural.
///
/// `LeylineStore` exposes three credential readers — `privateKey(for:)`,
/// `passphrase(for:)` and `password(for:)` — plus two credential *writers*,
/// `importKey` and `setPassword`. Anything reachable from an MCP tool handler
/// can end up in a chat transcript, and transcripts are persisted and
/// shareable. A private key that reaches a transcript is a private key that has
/// left the machine.
///
/// The obvious implementation hands `LeylineMCPOperations` the `LeylineStore`
/// and relies on nobody ever writing `store.privateKey(...)` in that file. That
/// is a convention, and conventions are enforced by code review — which is to
/// say, not enforced. So the MCP sink is given this instead: three closures
/// that return only value types, and no `LeylineStore` reference of any kind.
///
/// The consequence is a COMPILE-TIME guarantee. `LeylineMCPOperations` has no
/// property, parameter or capture through which a store can be reached, so
/// `privateKey(for:)` is not merely un-called there — it is *uncallable*. A
/// future edit that wanted to leak a key would have to change this file first,
/// which is exactly the review surface you want the change to land on.
///
/// ## Why the payload types are safe to hand over
///
/// `LeylineConnection` and `LeylineKey` are pure metadata by construction: the
/// secrets live in the Keychain under ids *derived* from these structs
/// (`passwordSecretID`, `privateKeySecretID`, `passphraseSecretID`), and the
/// structs carry only the id. Handing them across this boundary therefore
/// cannot carry secret material, and `LeylineMCPOperations` further narrows
/// what it prints to the fields the tool contract names.
///
/// The derived *secret ids* are not secrets, but they are not published either:
/// they are Keychain lookup keys and naming them in a transcript is free
/// reconnaissance with no benefit to the model.
///
/// ## The one closure that touches a secret — and why it is still safe
///
/// `identity` reads the private key out of the vault and writes it to a 0600
/// file so `ssh` can use it. That is what the Connect button has always done,
/// and it is what makes an agent-initiated connect actually authenticate
/// instead of failing with `Permission denied`.
///
/// What crosses the boundary is unchanged in kind: a value type carrying no
/// key material. The new hazard is the *path*, which names a plaintext copy of
/// the key — so it is wrapped in `MaterializedIdentity` rather than returned as
/// a `String`, and printing that wrapper yields `<materialized identity>`. The
/// invariant "nothing derived from a secret reaches tool output" therefore
/// survives an author who forgets it.
@MainActor
struct LeylineCatalog {
    /// Saved connections, metadata only.
    let connections: @MainActor () -> [LeylineConnection]
    /// Imported keys, metadata only. Never key material.
    let keys: @MainActor () -> [LeylineKey]
    /// Hands a validated SSH launch to the host's Rune app and reports what
    /// happened. Injected rather than reached through `HostServices` so the
    /// tests can drive every `PluginLaunchOutcome` case without a live host.
    let launch: @MainActor (SSHLaunchPayload) -> PluginLaunchOutcome
    /// Makes one connection's key readable by `ssh` and answers with the *path*
    /// — never the material. This is the one capability here that touches the
    /// Keychain, and it is deliberately shaped so what comes back cannot be a
    /// secret: `SSHIdentityResolution` carries a `MaterializedIdentity`, whose
    /// `description` is a redaction, so the path cannot reach tool output by
    /// interpolation. `LeylineMCPOperations` passes it straight into an
    /// `SSHLaunchPayload` and never prints it.
    let identity: @MainActor (LeylineConnection) -> SSHIdentityResolution

    init(
        connections: @escaping @MainActor () -> [LeylineConnection],
        keys: @escaping @MainActor () -> [LeylineKey],
        launch: @escaping @MainActor (SSHLaunchPayload) -> PluginLaunchOutcome,
        identity: @escaping @MainActor (LeylineConnection) -> SSHIdentityResolution
    ) {
        self.connections = connections
        self.keys = keys
        self.launch = launch
        self.identity = identity
    }

    /// Builds the catalog the plugin actually runs with: reads projected off
    /// the live `LeylineStore` the window is showing, and a launch that speaks
    /// to the host's app launcher.
    ///
    /// The `store` capture is confined to THIS initializer, and each closure
    /// body reads exactly one non-secret property. That confinement is what
    /// makes the compile-time claim above true: the store never crosses into
    /// `LeylineMCPOperations`.
    init(store: LeylineStore, launcher: PluginAppLauncher) {
        self.connections = { store.connections }
        self.keys = { store.keys }
        self.launch = { payload in
            // `openReportingOutcome` is the opt-in richer launcher, discovered
            // by dynamic cast. On a host that predates it, fall back to the
            // Void-returning `open` — which cannot distinguish success from a
            // missing Rune, so it must report `.opened` optimistically.
            // The UI's connect button makes the same trade in `LeylineRootView`.
            if let reporting = launcher as? PluginAppLauncherResult {
                return reporting.openReportingOutcome(appID: "rune", payload: payload.json)
            }
            launcher.open(appID: "rune", payload: payload.json)
            return .opened
        }
        self.identity = { conn in SSHIdentityResolver.resolve(conn, store: store) }
    }
}

import SwiftUI
import AinkradAppKit

public struct LeylineApp: AinkradApp {
    public static let id = "leyline"
    public static let displayName = "Leyline"
    public static let icon = "point.3.connected.trianglepath.dotted"

    /// Keyed by the host-minted instance id rather than
    /// `ObjectIdentifier(host)` — an address of a box around a non-class-bound
    /// existential, reusable after free, and never evicted. See
    /// `PluginInstanceStorage`.
    @MainActor private static let stores = PluginInstanceStorage<LeylineStore>()

    /// The instance key for `host`.
    ///
    /// A generation-8 host mints one. A generation-7 host does not implement
    /// `PluginInstanceIdentity`, so fall back to the OLD per-host object
    /// identity rather than to one shared id — collapsing every legacy host
    /// onto a single key would make two hosts share a store, which is a
    /// regression rather than a fallback. The address-reuse hazard stays only
    /// on the legacy path, exactly as before, and is gone on generation 8.
    @MainActor private static func instance(of host: HostServices) -> PluginInstanceID {
        if let identified = host as? PluginInstanceIdentity { return identified.instanceID }
        let key = ObjectIdentifier(host as AnyObject)
        if let existing = legacyIDs[key] { return existing }
        let minted = PluginInstanceID()
        legacyIDs[key] = minted
        return minted
    }
    @MainActor private static var legacyIDs: [ObjectIdentifier: PluginInstanceID] = [:]

    @MainActor private static func store(for host: HostServices) -> LeylineStore {
        stores.value(for: instance(of: host)) {
            LeylineStore(documents: host.documents, secrets: host.secrets)
        }
    }

    /// The per-host MCP server, created once and cached — the same shape as
    /// `stores`, keyed by the same instance id, because the server MUST read the
    /// store the window is showing. Building a fresh `LeylineStore` per call
    /// would hand the assistant a detached second copy that reloads the document
    /// from disk and never sees a connection the user just added.
    @MainActor private static let mcpServers = PluginInstanceStorage<MCPAppServer>()

    @MainActor static func mcpServer(for host: HostServices) -> MCPAppServer {
        mcpServers.value(for: instance(of: host)) {
            // `LeylineCatalog(store:launcher:)` is the ONLY place the store
            // crosses into the MCP layer, and it crosses as three closures over
            // non-secret value types. `LeylineMCPOperations` therefore has no
            // route to `privateKey`/`passphrase`/`password` — see that type.
            let operations = LeylineMCPOperations(
                catalog: LeylineCatalog(store: store(for: host), launcher: host.apps))
            let (server, failures) = LeylineMCPServer.make(
                appID: id,
                perform: { json in await operations.run(json) })
            // A dropped tool is a silently missing capability — say so rather
            // than let the assistant just never see it.
            if !failures.isEmpty {
                host.log.error("Leyline MCP: tools rejected — \(failures.joined(separator: ", "))")
            }
            return server
        }
    }

    /// The `leyline.resolve_connection` registration for one instance, kept
    /// with the provider that owns it so `teardown` can actually unregister —
    /// `AinkradAppTeardown.teardown(instance:)` gets no `HostServices`.
    private struct ActionRegistration {
        let provider: AgentActionProvider
        let token: AgentActionToken
    }
    @MainActor private static let actionTokens = PluginInstanceStorage<ActionRegistration>()

    /// Registers this host's **host-only** action, once per instance.
    ///
    /// This is not an MCP tool and must never become one: its reply carries
    /// `identityPath`, a filesystem path to a plaintext private key. Registering
    /// through `host.actions` puts it in `AgentActionRegistryHub`, which only
    /// host code invokes — see `LeylineConnectionBridge`.
    ///
    /// Called from `makeMCPServer` as well as `makeRootView` because the whole
    /// point is headless execution: the bridge has to answer with no Leyline
    /// window open, and `makeRootView` runs only when one is.
    @MainActor static func registerActions(for host: HostServices) {
        let id = instance(of: host)
        _ = actionTokens.value(for: id) {
            let store = store(for: host)
            let bridge = LeylineConnectionBridge(
                connections: { store.connections },
                keys: { store.keys },
                identity: { SSHIdentityResolver.resolve($0, store: store) })
            let token = host.actions.register(actionID: LeylineConnectionBridge.actionID) { json in
                bridge.resolve(json)
            }
            return ActionRegistration(provider: host.actions, token: token)
        }
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        makeRootView(host: host, mode: .advanced)
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(LeylineSettingsView(presentation: host.presentation, modeControl: host.mode))
    }

    public static func chromeFill(host: HostServices) -> Color? {
        host.theme.tokens.background
    }
}

/// Publishes Leyline's connection catalogue to the host assistant as MCP tools.
/// Cached per host by `mcpServer(for:)`, so the assistant reads the same store
/// the window shows.
extension LeylineApp: AinkradAppMCP {
    public static func makeMCPServer(host: HostServices) -> MCPAppServer {
        // The host resolves this at plugin load, which is the earliest reliable
        // hook a headless plugin gets — so the connection bridge is live before
        // anyone opens Leyline's window.
        registerActions(for: host)
        return mcpServer(for: host)
    }
}

/// Generation 8: purge materialized private keys when this instance closes.
///
/// `SSHKeyMaterializer` writes plaintext private keys to Application Support so
/// the system `ssh` binary can read them. Without a teardown hook they simply
/// stayed there — the audit's "materialized private keys written to disk in
/// plaintext, never deleted". Removing the key from the vault now purges its
/// copy (Wave 2); closing the app purges all of them.
extension LeylineApp: AinkradAppTeardown {
    public static func teardown(instance: PluginInstanceID) {
        stores.remove(instance)
        // The MCP server's tool closures capture the catalog, which captures
        // this instance's store. Leaving it registered would keep a closed
        // instance's connection list alive for the rest of the process and let
        // the assistant keep connecting through an app the user shut.
        mcpServers.remove(instance)
        // The action handler captures this instance's store too, so leaving it
        // registered would let the host keep resolving connections through an
        // app the user shut.
        if let registration = actionTokens.remove(instance) {
            registration.provider.remove(registration.token)
        }
        SSHKeyMaterializer.purgeAll()
    }
}

/// Generation 11: Leyline has a basic mode — pick a connection, connect.
///
/// Opt-in by conformance, found by the host's cast, so an SDK that gains this
/// does not require anything of an app that has no use for it.
extension LeylineApp: AinkradAppModes {
    public static func makeRootView(host: HostServices, mode: PluginMode) -> AnyView {
        registerActions(for: host)
        let store = store(for: host)
        switch mode {
        case .basic:
            return AnyView(LeylineBasicView(store: store, theme: host.theme, launcher: host.apps))
        case .advanced:
            return AnyView(LeylineRootView(store: store, theme: host.theme, launcher: host.apps))
        // `PluginMode` lives in a resilient module, so a newer SDK may add a
        // case this build has never seen. Fall back to ADVANCED: showing
        // everything is always correct, while guessing "basic" would hide
        // controls for a mode we do not understand.
        @unknown default:
            return AnyView(LeylineRootView(store: store, theme: host.theme, launcher: host.apps))
        }
    }
}

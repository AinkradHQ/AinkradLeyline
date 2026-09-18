import Testing
import SwiftUI
import AinkradAppKit
@testable import LeylineFeature

/// Leyline's basic mode.
///
/// The milestone's standing criterion is "basic must not construct the advanced
/// load". Leyline is the honest exception: it has no view models and no startup
/// load — one store, shared by both modes — which is exactly why it was picked
/// as the first adopter. So these cover the two things that CAN regress here:
/// that the app is reachable through the host's cast, and that connect stayed a
/// single implementation rather than being copied for the new mode.
@Suite("Leyline — basic mode")
@MainActor
struct LeylineBasicModeTests {

    private func conn(host: String = "example.com") -> LeylineConnection {
        LeylineConnection(id: UUID(), label: "box", host: host, port: 22,
                          username: "ahmed", authMode: .password, keyID: nil, createdAt: Date())
    }

    @Test("Leyline opts into modes, so the host's cast finds it")
    func optsIntoModes() {
        #expect((LeylineApp.self as Any) as? AinkradAppModes.Type != nil)
    }

    @Test("Both modes build")
    func bothModesBuild() {
        let host = BasicModeHost()
        _ = LeylineApp.makeRootView(host: host, mode: .basic)
        _ = LeylineApp.makeRootView(host: host, mode: .advanced)
    }

    @Test("The mode-less entry point still works, and means advanced")
    func legacyEntryPointMeansAdvanced() {
        // A generation-10 host calls this one. It must keep behaving exactly as
        // it did, or moving the pin changes what an un-updated host renders.
        _ = LeylineApp.makeRootView(host: BasicModeHost())
    }

    @Test("Connect is ONE implementation, reached from both modes")
    func connectIsShared() {
        // The bug this guards is one this code has already had: while key
        // resolution lived inside the view, the agent path had to duplicate it
        // or go without a key — it went without, and users got Permission
        // denied. A second copy for basic mode is the same mistake.
        let host = BasicModeHost()
        let store = LeylineStore(documents: host.documents, secrets: host.secrets)
        let error = LeylineConnectAction.connect(conn(), store: store, launcher: host.apps)
        #expect(error == nil, "a valid connection should report no failure")
        #expect(host.launcher.opened.count == 1)
        #expect(host.launcher.opened.first?.appID == "rune")
    }

    @Test("An unsafe connection is refused before it reaches ssh")
    func unsafeConnectionNeverLaunches() {
        // Every field lands in an `ssh` argv, and ssh's option surface
        // (-o ProxyCommand=…) runs shell commands, so this is the security
        // boundary — and basic mode must not be a way around it.
        let host = BasicModeHost()
        let store = LeylineStore(documents: host.documents, secrets: host.secrets)
        let hostile = conn(host: "-oProxyCommand=touch /tmp/pwned")
        let error = LeylineConnectAction.connect(hostile, store: store, launcher: host.apps)
        #expect(error != nil)
        #expect(host.launcher.opened.isEmpty, "a refused connection must never be launched")
    }

    @Test("A missing Rune is reported, not swallowed")
    func missingRuneIsReported() {
        let host = BasicModeHost()
        host.launcher.outcome = .unknownApp("rune")
        let store = LeylineStore(documents: host.documents, secrets: host.secrets)
        let error = LeylineConnectAction.connect(conn(), store: store, launcher: host.apps)
        #expect(error?.contains("isn't installed") == true)
    }
}

// MARK: - Fakes

@MainActor
private final class BasicModeLauncher: PluginAppLauncher, PluginAppLauncherResult {
    struct Open: Equatable { let appID: String; let payload: String? }
    var opened: [Open] = []
    var outcome: PluginLaunchOutcome = .opened

    func open(appID: String, payload: String?) {
        _ = openReportingOutcome(appID: appID, payload: payload)
    }
    func openReportingOutcome(appID: String, payload: String?) -> PluginLaunchOutcome {
        if case .opened = outcome { opened.append(Open(appID: appID, payload: payload)) }
        return outcome
    }
    func takePendingLaunch() -> String? { nil }
}

@MainActor
private final class BasicModeHost: HostServices {
    let documents: PluginDocumentStore = FakeDocs()
    let secrets: PluginSecretStore = FakeSecrets()
    let launcher = BasicModeLauncher()

    var theme: HostTheme {
        HostTheme(.init(themeID: "t", background: .black, surface: .black,
                        surfaceElevated: .black, accentPrimary: .white,
                        accentSecondary: .white, accentTertiary: .white, foreground: .white))
    }
    var log: PluginLogger { FakeLog() }
    var context: PluginContextRegistry { FakeContext() }
    var actions: AgentActionProvider { FakeActions() }
    var apps: PluginAppLauncher { launcher }
    var presentation: PluginPresentationControl { FakePresentation() }
    var mode: PluginModeControl { FakeMode() }
    var signals: PluginSignalEmitter { NoopSignalEmitter() }
}

private struct FakeLog: PluginLogger {
    func info(_ message: String) {}
    func error(_ message: String) {}
}
@MainActor private struct FakeContext: PluginContextRegistry {
    func register(_ source: @escaping @MainActor () -> AgentContextSnapshot?) -> PluginContextToken {
        PluginContextToken()
    }
    func remove(_ token: PluginContextToken) {}
}
@MainActor private struct FakeActions: AgentActionProvider {
    func register(actionID: String,
                  handler: @escaping @MainActor (String) async -> AgentActionResult) -> AgentActionToken {
        AgentActionToken()
    }
    func remove(_ token: AgentActionToken) {}
}
@MainActor private struct FakePresentation: PluginPresentationControl {
    var current: PluginPresentation { .overlay }
    func set(_ presentation: PluginPresentation) {}
    func reset() {}
}
@MainActor private struct FakeMode: PluginModeControl {
    var current: PluginMode { .basic }
    func set(_ mode: PluginMode) {}
    func reset() {}
}

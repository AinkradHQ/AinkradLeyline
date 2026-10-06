import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

/// Closing an instance must drop everything that captured its store: the
/// store itself, the MCP server and the host-only action.
@MainActor
@Suite("Leyline teardown")
struct LeylineTeardownTests {
    @Test("the host-only action registers once per instance and unregisters on teardown")
    func actionRegistersOnceAndUnregisters() throws {
        let host = BasicModeHost()
        _ = LeylineApp.makeMCPServer(host: host)
        _ = LeylineApp.makeRootView(host: host, mode: .advanced)
        let registration = try #require(host.actionRecorder.registered.first)
        #expect(host.actionRecorder.registered.count == 1)
        #expect(registration.actionID == LeylineConnectionBridge.actionID)

        LeylineApp.teardown(instance: host.instanceID)

        #expect(host.actionRecorder.removed == [registration.token])
    }

    @Test("teardown drops the instance's MCP server and store")
    func teardownDropsServerAndStore() {
        let host = BasicModeHost()
        let server = LeylineApp.makeMCPServer(host: host)
        let store = LeylineApp.store(for: host)
        #expect(LeylineApp.mcpServer(for: host) === server)

        LeylineApp.teardown(instance: host.instanceID)

        #expect(LeylineApp.mcpServer(for: host) !== server)
        #expect(LeylineApp.store(for: host) !== store)
        LeylineApp.teardown(instance: host.instanceID)
    }

    @Test("tearing down an instance that never opened is harmless")
    func teardownOfUnknownInstance() {
        let host = BasicModeHost()
        LeylineApp.teardown(instance: host.instanceID)
        #expect(host.actionRecorder.removed.isEmpty)
    }
}

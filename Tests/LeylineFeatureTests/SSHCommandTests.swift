import Foundation
import Testing

@testable import LeylineFeature

@Suite("SSHCommand")
struct SSHCommandTests {
    private func conn(
        port: Int = 22, user: String = "deploy", host: String = "example.com",
        auth: LeylineConnection.AuthMode = .password
    ) -> LeylineConnection {
        LeylineConnection(
            id: UUID(), label: "l", host: host, port: port, username: user,
            authMode: auth, keyID: nil, createdAt: Date())
    }

    @Test("default port is omitted")
    func defaultPort() {
        #expect(SSHCommand.string(for: conn()) == "ssh deploy@example.com")
    }

    @Test("non-default port adds -p")
    func customPort() {
        #expect(SSHCommand.string(for: conn(port: 2222)) == "ssh -p 2222 deploy@example.com")
    }

    @Test("empty username drops the user@ prefix")
    func noUser() {
        #expect(SSHCommand.string(for: conn(user: "")) == "ssh example.com")
    }
}

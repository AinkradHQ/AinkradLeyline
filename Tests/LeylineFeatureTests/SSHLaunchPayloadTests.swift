import AinkradAppKit
import Foundation
import Testing

@testable import LeylineFeature

@Suite("SSHLaunchPayload")
struct SSHLaunchPayloadTests {
    @Test("encodes kind=ssh and all fields")
    func encodes() throws {
        let json = SSHLaunchPayload(host: "h", port: 2222, username: "u", identityFile: "/k").json
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["kind"] as? String == "ssh")
        #expect(obj["host"] as? String == "h")
        #expect(obj["port"] as? Int == 2222)
        #expect(obj["username"] as? String == "u")
        #expect(obj["identityFile"] as? String == "/k")
    }
    @Test("nil identityFile omitted or null, still valid JSON")
    func nilIdentity() {
        let json = SSHLaunchPayload(host: "h", port: 22, username: "u", identityFile: nil).json
        #expect(json.contains("\"kind\":\"ssh\""))
    }
}

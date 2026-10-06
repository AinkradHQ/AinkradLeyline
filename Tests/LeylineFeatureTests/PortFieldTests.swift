import Testing

@testable import LeylineFeature

@Suite("PortField")
struct PortFieldTests {
    @Test("valid ports parse", arguments: [("22", 22), ("1", 1), ("2222", 2222), ("65535", 65535)])
    func valid(text: String, value: Int) {
        #expect(PortField.parse(text) == value)
    }

    @Test(
        "invalid ports are rejected, never defaulted to 22",
        arguments: ["", " ", "0", "65536", "99999999999999999999", "-1", "+22", "22a", "2 2", "abc", "٢٢"])
    func invalid(text: String) {
        #expect(PortField.parse(text) == nil)
    }
}

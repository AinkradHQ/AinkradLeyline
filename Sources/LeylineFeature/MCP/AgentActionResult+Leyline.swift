import AinkradAppKit

/// Shorthand for the two reply shapes every Leyline MCP and host-bridge
/// answer takes.
extension AgentActionResult {
    static func success(_ text: String) -> AgentActionResult { .init(text: text, isError: false) }
    static func failure(_ text: String) -> AgentActionResult { .init(text: text, isError: true) }
}

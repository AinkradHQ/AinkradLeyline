import Foundation

/// Builds the `ssh` command a connection row shows and copies. It never names
/// a key file: the materialized key path is for Rune's launch payload only.
enum SSHCommand {
    static func string(for c: LeylineConnection) -> String {
        var parts = ["ssh"]
        if c.port != 22 { parts += ["-p", String(c.port)] }
        parts.append(c.username.isEmpty ? c.host : "\(c.username)@\(c.host)")
        return parts.joined(separator: " ")
    }
}

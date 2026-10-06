import Foundation

/// Case-insensitive type-to-filter over label, host, and username.
public enum ConnectionFilter {
    public static func matching(_ query: String, in connections: [LeylineConnection]) -> [LeylineConnection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return connections }
        return connections.filter {
            $0.label.lowercased().contains(q)
                || $0.host.lowercased().contains(q)
                || $0.username.lowercased().contains(q)
        }
    }
}

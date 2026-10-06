import Foundation

/// The single persisted, non-secret document for Leyline.
struct LeylineDocument: Codable, Equatable {
    static let documentID = "leyline"
    var connections: [LeylineConnection]
    var keys: [LeylineKey]

    init(connections: [LeylineConnection] = [], keys: [LeylineKey] = []) {
        self.connections = connections
        self.keys = keys
    }
}

import Foundation

/// Validation seam for the connection editor's port field.
enum PortField {
    /// Old behaviour, kept as the failing baseline: anything unparsable became 22.
    static func parse(_ text: String) -> Int? { Int(text) ?? 22 }
    static let errorMessage = ""
}

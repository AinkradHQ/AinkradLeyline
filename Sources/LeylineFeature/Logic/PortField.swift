import Foundation

/// Validation seam for the connection editor's port field.
enum PortField {
    /// ASCII digits only, 1...65535. `nil` means invalid — never a silent default.
    static func parse(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }
    static let errorMessage = "Port must be a number from 1 to 65535"
}

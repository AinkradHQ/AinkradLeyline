import Foundation

/// Reads a key file chosen in the vault's import panel.
enum KeyImportFile {
    /// Old behaviour, kept as the failing baseline: failures were swallowed.
    static func read(_ url: URL) -> Result<String, KeyImportError> {
        .success((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }
}

struct KeyImportError: Error, Equatable { let message: String }

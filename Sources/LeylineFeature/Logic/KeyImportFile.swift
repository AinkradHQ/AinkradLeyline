import Foundation

/// Reads a key file chosen in the vault's import panel.
enum KeyImportFile {
    static func read(_ url: URL) -> Result<String, KeyImportError> {
        let name = url.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return .failure(KeyImportError(message: "Couldn't read \(name): \(error.localizedDescription)"))
        }
        guard let body = String(data: data, encoding: .utf8) else {
            return .failure(KeyImportError(message: "\(name) isn't a text file, so it can't be a private key"))
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(KeyImportError(message: "\(name) is empty"))
        }
        return .success(body)
    }
}

struct KeyImportError: Error, Equatable { let message: String }

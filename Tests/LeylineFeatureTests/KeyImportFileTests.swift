import Testing
import Foundation
@testable import LeylineFeature

@Suite("KeyImportFile")
struct KeyImportFileTests {
    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyimport-\(UUID()).bin")
        try data.write(to: url)
        return url
    }

    @Test("a readable text file returns its body")
    func readable() throws {
        let url = try tempFile(Data("-----BEGIN-----".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try KeyImportFile.read(url).get() == "-----BEGIN-----")
    }

    @Test("a missing file fails with a message")
    func missing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")
        guard case .failure(let e) = KeyImportFile.read(url) else { Issue.record("expected failure"); return }
        #expect(!e.message.isEmpty)
    }

    @Test("a binary (non-UTF-8) file fails with a message")
    func binary() throws {
        let url = try tempFile(Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE, 0x00]))
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .failure(let e) = KeyImportFile.read(url) else { Issue.record("expected failure"); return }
        #expect(!e.message.isEmpty)
    }

    @Test("an empty file fails with a message")
    func empty() throws {
        let url = try tempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .failure = KeyImportFile.read(url) else { Issue.record("expected failure"); return }
    }
}

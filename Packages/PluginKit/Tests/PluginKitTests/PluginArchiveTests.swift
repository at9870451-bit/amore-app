import Foundation
import Testing
import ZIPFoundation

@testable import PluginKit

private let manifestJSON = """
{
  "schemaVersion": 1,
  "id": "io.github.alice.echo",
  "name": "Echo",
  "version": "1.0.0",
  "minHostVersion": "1.0.0",
  "type": "js",
  "entry": "index.js",
  "author": { "name": "Alice" },
  "description": "echo",
  "permissions": ["storage"],
  "tools": [{ "name": "echo", "description": "echo back", "inputSchema": { "type": "object" } }]
}
"""

private func makeZip(_ entries: [(String, Data)], at url: URL) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in entries {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        )
    }
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("plugin-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("PluginArchive")
struct PluginArchiveTests {
    @Test("extracts a well-formed plugin and validates its manifest")
    func happyPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("plugin.zip")
        try makeZip([
            ("manifest.json", Data(manifestJSON.utf8)),
            ("index.js", Data("globalThis.plugin = { tools: { echo: async () => 'hi' } };".utf8))
        ], at: zip)

        let target = dir.appendingPathComponent("unpacked", isDirectory: true)
        let result = try PluginArchive.unpack(zipAt: zip, to: target)

        #expect(result.manifest.id == "io.github.alice.echo")
        #expect(result.permissions == [.storage])
        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("index.js").path))
    }

    @Test("rejects a path that escapes the destination")
    func zipSlip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("evil.zip")
        try makeZip([
            ("manifest.json", Data(manifestJSON.utf8)),
            ("../evil.txt", Data("pwned".utf8))
        ], at: zip)

        let target = dir.appendingPathComponent("unpacked", isDirectory: true)
        #expect(throws: PluginError.self) {
            _ = try PluginArchive.unpack(zipAt: zip, to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.txt").path))
    }

    @Test("rejects an archive with too many entries")
    func tooManyEntries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("big.zip")
        var entries: [(String, Data)] = [("manifest.json", Data(manifestJSON.utf8))]
        for index in 0..<520 {
            entries.append(("f\(index).txt", Data("x".utf8)))
        }
        try makeZip(entries, at: zip)

        let target = dir.appendingPathComponent("unpacked", isDirectory: true)
        #expect(throws: PluginError.self) {
            _ = try PluginArchive.unpack(zipAt: zip, to: target,
                                         limits: .init(maxEntries: 500))
        }
    }

    @Test("relative path helper rejects absolute and traversal forms")
    func safePathRules() {
        let root = URL(fileURLWithPath: "/tmp/plugin-root")
        #expect(PluginArchive.safeDestination(for: "index.js", root: root) != nil)
        #expect(PluginArchive.safeDestination(for: "/etc/passwd", root: root) == nil)
        #expect(PluginArchive.safeDestination(for: "../x", root: root) == nil)
        #expect(PluginArchive.safeDestination(for: "a/../../x", root: root) == nil)
        #expect(PluginArchive.safeDestination(for: "C:/x", root: root) == nil)
        #expect(PluginArchive.safeDestination(for: "a\\b", root: root) == nil)
    }
}
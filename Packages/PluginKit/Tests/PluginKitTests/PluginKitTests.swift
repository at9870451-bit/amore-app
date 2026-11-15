import Foundation
import Testing

@testable import PluginKit

private let validManifestJSON = """
{
  "schemaVersion": 1,
  "id": "io.github.alice.weather",
  "name": "Weather",
  "version": "1.2.0",
  "minHostVersion": "1.0.0",
  "type": "js",
  "entry": "index.js",
  "author": { "name": "Alice", "github": "alice" },
  "description": "查询天气",
  "icon": "icon.png",
  "permissions": ["network:api.open-meteo.com", "storage", "secrets", "notify"],
  "tools": [{
    "name": "get_weather",
    "description": "获取城市天气",
    "inputSchema": { "type": "object", "properties": { "city": { "type": "string" } }, "required": ["city"] }
  }],
  "settings": [{ "key": "unit", "type": "enum", "options": ["C", "F"], "default": "C" }]
}
"""

@Suite("PluginManifest")
struct PluginManifestTests {
    @Test("decodes the schema v1 example")
    func decode() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        #expect(manifest.id == "io.github.alice.weather")
        #expect(manifest.type == .js)
        #expect(manifest.permissions.count == 4)
        #expect(manifest.tools.first?.name == "get_weather")
        #expect(manifest.settings?.first?.type == .enum)
    }

    @Test("validator accepts a well-formed manifest")
    func valid() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        let permissions = try ManifestValidator().validate(manifest)
        #expect(permissions.contains(.storage))
        #expect(permissions.contains(.network(host: "api.open-meteo.com")))
    }

    @Test("rejects a non reverse-domain id")
    func badID() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.id = "Weather"
        #expect(throws: PluginError.invalidPluginID("Weather")) {
            _ = try ManifestValidator().validate(manifest)
        }
    }

    @Test("rejects a bad semver")
    func badVersion() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.version = "1.2"
        #expect(throws: PluginError.invalidVersion("1.2")) {
            _ = try ManifestValidator().validate(manifest)
        }
    }

    @Test("rejects tool names with dashes or uppercase")
    func badToolName() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.tools = [PluginToolDefinition(name: "Get-Weather", description: "", inputSchema: [:])]
        #expect(throws: PluginError.invalidToolName("Get-Weather")) {
            _ = try ManifestValidator().validate(manifest)
        }
    }

    @Test("rejects unknown permissions")
    func badPermission() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.permissions = ["filesystem"]
        #expect(throws: PluginError.unknownPermission("filesystem")) {
            _ = try ManifestValidator().validate(manifest)
        }
    }

    @Test("rejects http-ish or wildcard network hosts")
    func badHost() {
        #expect(PluginPermission.parse("network:https://evil.com") == nil)
        #expect(PluginPermission.parse("network:*.evil.com") == nil)
        #expect(PluginPermission.parse("network:evil.com/path") == nil)
        #expect(PluginPermission.parse("network:api.open-meteo.com") != nil)
    }

    @Test("rejects a plugin that needs a newer host")
    func hostTooOld() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.minHostVersion = "2.0.0"
        #expect(throws: PluginError.hostTooOld(required: "2.0.0", current: "1.0.0")) {
            _ = try ManifestValidator(hostVersion: "1.0.0").validate(manifest)
        }
    }

    @Test("js plugins must ship a relative .js entry")
    func entryRequired() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.entry = "../escape.js"
        #expect(throws: PluginError.self) {
            _ = try ManifestValidator().validate(manifest)
        }
    }

    @Test("mcp plugins need a server block, prompt plugins need templates")
    func typeSpecific() throws {
        var manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(validManifestJSON.utf8))
        manifest.type = .mcp
        manifest.entry = nil
        #expect(throws: PluginError.self) { _ = try ManifestValidator().validate(manifest) }

        manifest.type = .prompt
        manifest.templates = []
        #expect(throws: PluginError.self) { _ = try ManifestValidator().validate(manifest) }
    }
}

@Suite("PluginStateMachine")
struct PluginStateMachineTests {
    @Test("happy path install → enable → uninstall")
    func happyPath() throws {
        var machine = PluginStateMachine()
        try machine.transition(to: .downloading)
        try machine.transition(to: .verifying)
        try machine.transition(to: .installedDisabled)
        try machine.transition(to: .enabled)
        #expect(machine.state.isRunnable)
        try machine.transition(to: .installedDisabled)
        try machine.transition(to: .notInstalled)
        #expect(machine.state == .notInstalled)
    }

    @Test("cannot jump straight to enabled")
    func illegalJump() {
        var machine = PluginStateMachine()
        #expect(throws: PluginError.self) { try machine.transition(to: .enabled) }
    }

    @Test("failure can retry from the failed state")
    func failureRetry() throws {
        var machine = PluginStateMachine()
        try machine.transition(to: .downloading)
        try machine.transition(to: .failed)
        try machine.transition(to: .downloading)
        #expect(machine.state == .downloading)
    }

    @Test("disabling and updating are both reachable from enabled")
    func enabledPaths() throws {
        for next in [PluginState.enabled, .installedDisabled, .updating, .notInstalled, .failed] {
            var machine = PluginStateMachine(state: .enabled)
            try machine.transition(to: next)
            #expect(machine.state == next)
        }
    }
}
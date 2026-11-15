import AgentKit
import CoreKit
import Foundation
import PluginKit
import PluginRuntimeJS

/// Bridges one sandboxed JS tool into the agent's tool registry.
///
/// Lives in the app layer on purpose: PluginRuntimeJS must not depend on
/// AgentKit (that would invert the module graph), and AgentKit must not depend
/// on JavaScriptCore.
struct PluginToolAdapter: AgentTool {
    let name: String
    let description: String
    let inputSchemaJSON: String
    private let host: JSPluginHost
    private let jsName: String
    private let logger: AmoreLogger

    init(pluginID: String, toolName: String, description: String,
         inputSchemaJSON: String, host: JSPluginHost, logger: AmoreLogger) {
        // `pluginId__toolName` keeps two plugins with the same tool name apart.
        self.name = "\(pluginID)__\(toolName)"
        self.jsName = toolName
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.host = host
        self.logger = logger
    }

    func execute(argumentsJSON: String) async throws -> String {
        do {
            return try await host.callTool(jsName, argumentsJSON: argumentsJSON)
        } catch let error as PluginError {
            // A disabled plugin must surface as a tool failure, not crash a run.
            if case .disabledAfterTimeouts = error {
                logger.warning("plugin tool disabled: \(name)")
            }
            throw AgentError.toolFailed(name: name, message: error.localizedDescription)
        }
    }
}

/// Registers (or re-registers) a plugin's tools. Called when a plugin is
/// enabled or updated, and the inverse when it is disabled.
struct PluginToolInstaller {
    let registry: ToolRegistry
    let logger: AmoreLogger

    func install(pluginID: String, host: JSPluginHost,
                 tools: [(name: String, description: String, inputSchemaJSON: String)]) async throws {
        let adapters = tools.map { tool in
            PluginToolAdapter(pluginID: pluginID, toolName: tool.name,
                              description: tool.description,
                              inputSchemaJSON: tool.inputSchemaJSON,
                              host: host, logger: logger)
        }
        await registry.register(adapters)
        logger.info("registered \(adapters.count) tool(s) for \(pluginID)")
    }

    func uninstall(pluginID: String) async {
        await registry.unregisterAll(prefix: "\(pluginID)__")
        logger.info("unregistered tools for \(pluginID)")
    }
}
import Foundation
import JavaScriptCore
import PluginKit

/// Capabilities a plugin may use. Injected so tests can stub them and so the
/// host — not the JS — decides what actually happens.
public protocol PluginStorage: Sendable {
    func get(_ key: String) async throws -> String?
    func set(_ key: String, value: String) async throws
    func remove(_ key: String) async throws
}

public protocol PluginSecrets: Sendable {
    func secret(_ key: String) async throws -> String?
}

public protocol PluginHTTP: Sendable {
    /// Must reject non-https URLs and enforce the manifest's network allowlist.
    func fetch(_ url: String, method: String, headers: [String: String],
               body: String?) async throws -> String
}

public protocol PluginNotifying: Sendable {
    func notify(title: String, body: String) async
}

public struct PluginHostLogger: Sendable {
    public var info: @Sendable (String) -> Void
    public var error: @Sendable (String) -> Void
    public init(info: @escaping @Sendable (String) -> Void,
                error: @escaping @Sendable (String) -> Void) {
        self.info = info
        self.error = error
    }
}

/// Runs one plugin's JavaScript. All JS touches one serial queue; the public
/// actor surface hides that from callers.
public actor JSPluginHost {
    public struct Limits: Sendable {
        public var timeoutSeconds: Int
        public var timeoutBudget: Int
        public var maxResponseBytes: Int
        public init(timeoutSeconds: Int = 30, timeoutBudget: Int = 3,
                    maxResponseBytes: Int = 5 * 1024 * 1024) {
            self.timeoutSeconds = timeoutSeconds
            self.timeoutBudget = timeoutBudget
            self.maxResponseBytes = maxResponseBytes
        }
    }

    let pluginID: String
    let permissions: [PluginPermission]
    private let limits: Limits
    let storage: any PluginStorage
    let secrets: any PluginSecrets
    let http: any PluginHTTP
    let notifier: any PluginNotifying
    let logger: PluginHostLogger

    private var runtime: JSPluginRuntime?
    private var consecutiveTimeouts = 0
    private var disabled = false

    public init(
        pluginID: String,
        permissions: [PluginPermission],
        storage: any PluginStorage,
        secrets: any PluginSecrets,
        http: any PluginHTTP,
        notifier: any PluginNotifying,
        logger: PluginHostLogger,
        limits: Limits = Limits()
    ) {
        self.pluginID = pluginID
        self.permissions = permissions
        self.storage = storage
        self.secrets = secrets
        self.http = http
        self.notifier = notifier
        self.logger = logger
        self.limits = limits
    }

    public var isDisabled: Bool { disabled }

    public func load(script: String) throws {
        guard !disabled else { throw PluginError.disabledAfterTimeouts(tool: "<host>") }
        let runtime = JSPluginRuntime(
            pluginID: pluginID,
            permissions: permissions,
            storage: storage,
            secrets: secrets,
            http: http,
            notifier: notifier,
            logger: logger,
            limits: limits
        )
        try runtime.load(script: script)
        self.runtime = runtime
    }

    public func callTool(_ name: String, argumentsJSON: String) async throws -> String {
        guard !disabled else { throw PluginError.disabledAfterTimeouts(tool: name) }
        guard let runtime else { throw PluginError.runtime("plugin is not loaded") }

        do {
            let value = try await runtime.invoke(tool: name, argumentsJSON: argumentsJSON)
            consecutiveTimeouts = 0
            return value
        } catch let error as PluginError {
            if case .timeout = error {
                consecutiveTimeouts += 1
                if consecutiveTimeouts >= limits.timeoutBudget {
                    disabled = true
                    logger.error("plugin \(pluginID) disabled after \(consecutiveTimeouts) timeouts")
                    throw PluginError.disabledAfterTimeouts(tool: name)
                }
            }
            throw error
        }
    }
}

// MARK: - Engine

/// Owns the JSVirtualMachine. A class (not an actor) because `JSContext` is
/// neither Sendable nor thread-safe; every access is funnelled through one
/// serial queue, and the unchecked conformance documents that invariant.
final class JSPluginRuntime: @unchecked Sendable {
    let queue = DispatchQueue(label: "amore.plugin.js")
    let virtualMachine = JSVirtualMachine()
    let context: JSContext
    let pluginID: String
    let permissions: [PluginPermission]
    let storage: any PluginStorage
    let secrets: any PluginSecrets
    let http: any PluginHTTP
    let notifier: any PluginNotifying
    let logger: PluginHostLogger
    let limits: JSPluginHost.Limits

    let lock = NSLock()
    var pending: [String: CheckedContinuation<String, Error>] = [:]

    init(pluginID: String, permissions: [PluginPermission],
         storage: any PluginStorage, secrets: any PluginSecrets,
         http: any PluginHTTP, notifier: any PluginNotifying,
         logger: PluginHostLogger, limits: JSPluginHost.Limits) {
        self.pluginID = pluginID
        self.permissions = permissions
        self.storage = storage
        self.secrets = secrets
        self.http = http
        self.notifier = notifier
        self.logger = logger
        self.limits = limits
        self.context = JSContext(virtualMachine: virtualMachine) ?? JSContext()
        installBootstrap()
    }

    // MARK: Load

    func load(script: String) throws {
        var thrown: Error?
        queue.sync {
            context.exceptionHandler = { [weak self] _, exception in
                let message = exception?.toString() ?? "unknown"
                self?.logger.error("js exception: \(message)")
            }
            context.evaluateScript(script, withSourceURL: URL(string: "amore://plugin/\(pluginID)/entry.js"))
            if let exception = context.exception {
                thrown = PluginError.runtime(exception.toString() ?? "script failed")
            }
        }
        if let thrown { throw thrown }
    }

    // MARK: Invoke

    func invoke(tool: String, argumentsJSON: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let callID = UUID().uuidString
            lock.lock(); pending[callID] = continuation; lock.unlock()

            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finish(callID, .failure(PluginError.timeout(tool: tool,
                                                                 seconds: self.limits.timeoutSeconds)))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(limits.timeoutSeconds),
                                              execute: timeout)

            queue.async { [weak self] in
                guard let self else { return }
                self.context.setObject(callID, forKeyedSubscript: "__amore_callid" as NSString)
                self.context.setObject(tool, forKeyedSubscript: "__amore_tool" as NSString)
                self.context.setObject(argumentsJSON, forKeyedSubscript: "__amore_args" as NSString)
                self.context.evaluateScript("""
                (function () {
                    try {
                        if (!globalThis.plugin || !plugin.tools || typeof plugin.tools[__amore_tool] !== 'function') {
                            __amore_done(__amore_callid, false, 'unknown tool: ' + __amore_tool);
                            return;
                        }
                        var result = plugin.tools[__amore_tool](JSON.parse(__amore_args), {});
                        Promise.resolve(result).then(function (value) {
                            __amore_done(__amore_callid, true, JSON.stringify(value === undefined ? null : value));
                        }).catch(function (error) {
                            __amore_done(__amore_callid, false, String((error && error.message) || error));
                        });
                    } catch (error) {
                        __amore_done(__amore_callid, false, String((error && error.message) || error));
                    }
                })();
                """)
                if let exception = self.context.exception {
                    self.finish(callID, .failure(PluginError.runtime(exception.toString() ?? "invoke failed")))
                }
            }
        }
    }

    func finish(_ callID: String, _ result: Result<String, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: callID)
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
    }
}
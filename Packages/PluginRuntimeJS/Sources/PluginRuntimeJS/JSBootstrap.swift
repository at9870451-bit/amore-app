import Foundation
import JavaScriptCore
import PluginKit

extension JSPluginRuntime {
    /// Installs the sandbox globals before any plugin code runs.
    ///
    /// - Removes `eval` and `Function` so a plugin cannot compile new code.
    /// - Exposes only `amore.*`, each call returning a Promise that the host
    ///   resolves after its own permission check and I/O.
    func installBootstrap() {
        let bootstrap = """
        (function () {
            'use strict';
            try { globalThis.eval = undefined; } catch (e) {}
            try { globalThis.Function = undefined; } catch (e) {}

            globalThis.__amore_pending = {};
            globalThis.__amore_seq = 0;
            globalThis.__amore_timers = {};

            globalThis.__amore_call = function (name, payload) {
                return new Promise(function (resolve, reject) {
                    var id = String(++globalThis.__amore_seq);
                    globalThis.__amore_pending[id] = { resolve: resolve, reject: reject };
                    __amore_dispatch(id, name, JSON.stringify(payload));
                });
            };

            globalThis.__amore_resolve = function (id, ok, value) {
                var entry = globalThis.__amore_pending[id];
                if (!entry) { return; }
                delete globalThis.__amore_pending[id];
                if (ok) { entry.resolve(JSON.parse(value)); }
                else { entry.reject(new Error(value)); }
            };

            globalThis.setTimeout = function (fn, ms) {
                var id = String(++globalThis.__amore_seq);
                globalThis.__amore_timers[id] = fn;
                __amore_schedule(id, Math.max(0, ms | 0));
                return id;
            };
            globalThis.clearTimeout = function (id) { delete globalThis.__amore_timers[id]; };
            globalThis.__amore_fire = function (id) {
                var fn = globalThis.__amore_timers[id];
                delete globalThis.__amore_timers[id];
                if (typeof fn === 'function') { try { fn(); } catch (e) {} }
            };

            globalThis.amore = {
                http: {
                    fetch: function (url, options) {
                        return __amore_call('http.fetch', { url: String(url), options: options || {} });
                    }
                },
                storage: {
                    get: function (key) { return __amore_call('storage.get', { key: String(key) }); },
                    set: function (key, value) { return __amore_call('storage.set', { key: String(key), value: String(value) }); },
                    remove: function (key) { return __amore_call('storage.remove', { key: String(key) }); }
                },
                secrets: {
                    get: function (key) { return __amore_call('secrets.get', { key: String(key) }); }
                },
                notify: function (title, body) {
                    return __amore_call('notify', { title: String(title), body: String(body) });
                },
                log: {
                    info: function (message) { return __amore_call('log.info', { message: String(message) }); },
                    error: function (message) { return __amore_call('log.error', { message: String(message) }); }
                }
            };
        })();
        """
        context.evaluateScript(bootstrap)
        if let exception = context.exception {
            logger.error("bootstrap failed: \(exception.toString() ?? "?")")
            return
        }

        // __amore_done: invoked by the generated invoke wrapper.
        let done: @convention(block) (String?, Bool, String?) -> Void = { [weak self] id, ok, payload in
            guard let self, let id else { return }
            if ok {
                self.finish(id, .success(payload ?? "null"))
            } else {
                self.finish(id, .failure(PluginError.runtime(payload ?? "unknown")))
            }
        }
        context.setObject(unsafeBitCast(done, to: AnyObject.self), forKeyedSubscript: "__amore_done" as NSString)

        // __amore_dispatch: the single funnel into Swift capabilities.
        let dispatcher: @convention(block) (String?, String?, String?) -> Void = { [weak self] callID, name, payload in
            guard let self, let callID, let name, let payload else { return }
            self.dispatch(callID: callID, name: name, payloadJSON: payload)
        }
        context.setObject(unsafeBitCast(dispatcher, to: AnyObject.self), forKeyedSubscript: "__amore_dispatch" as NSString)

        // __amore_schedule: host timers, so plugins cannot spin the JS thread.
        let scheduler: @convention(block) (String?, Int) -> Void = { [weak self] id, milliseconds in
            guard let self, let id else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(0, milliseconds))) {
                self.queue.async {
                    self.context.evaluateScript("__amore_fire('\(id)')")
                }
            }
        }
        context.setObject(unsafeBitCast(scheduler, to: AnyObject.self), forKeyedSubscript: "__amore_schedule" as NSString)
    }

    /// Routes one capability call, enforcing both the manifest permissions and
    /// the per-capability limits.
    func dispatch(callID: String, name: String, payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            resolve(callID, ok: false, value: "bad payload")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                switch name {
                case "http.fetch":
                    let url = (payload["url"] as? String) ?? ""
                    guard let host = Self.host(of: url) else {
                        throw PluginError.permissionDenied("network")
                    }
                    guard PluginPermissionCatalog.allowedHosts(self.permissions).contains(host) else {
                        throw PluginError.permissionDenied("network:\(host)")
                    }
                    let options = (payload["options"] as? [String: Any]) ?? [:]
                    let method = (options["method"] as? String) ?? "GET"
                    let headers = (options["headers"] as? [String: String]) ?? [:]
                    let body = options["body"] as? String
                    let value = try await self.http.fetch(url, method: method, headers: headers, body: body)
                    guard value.utf8.count <= self.limits.maxResponseBytes else {
                        throw PluginError.responseTooLarge(limitBytes: self.limits.maxResponseBytes)
                    }
                    self.resolve(callID, ok: true, value: value)

                case "storage.get":
                    guard self.has(.storage) else { throw PluginError.permissionDenied("storage") }
                    let key = (payload["key"] as? String) ?? ""
                    let value = try await self.storage.get(key) ?? ""
                    self.resolve(callID, ok: true, value: value)

                case "storage.set":
                    guard self.has(.storage) else { throw PluginError.permissionDenied("storage") }
                    let key = (payload["key"] as? String) ?? ""
                    let value = (payload["value"] as? String) ?? ""
                    try await self.storage.set(key, value: value)
                    self.resolve(callID, ok: true, value: "1")

                case "storage.remove":
                    guard self.has(.storage) else { throw PluginError.permissionDenied("storage") }
                    try await self.storage.remove((payload["key"] as? String) ?? "")
                    self.resolve(callID, ok: true, value: "1")

                case "secrets.get":
                    guard self.has(.secrets) else { throw PluginError.permissionDenied("secrets") }
                    let value = try await self.secrets.secret((payload["key"] as? String) ?? "") ?? ""
                    self.resolve(callID, ok: true, value: value)

                case "notify":
                    guard self.has(.notify) else { throw PluginError.permissionDenied("notify") }
                    await self.notifier.notify(title: (payload["title"] as? String) ?? "",
                                               body: (payload["body"] as? String) ?? "")
                    self.resolve(callID, ok: true, value: "1")

                case "log.info":
                    self.logger.info((payload["message"] as? String) ?? "")
                    self.resolve(callID, ok: true, value: "1")

                case "log.error":
                    self.logger.error((payload["message"] as? String) ?? "")
                    self.resolve(callID, ok: true, value: "1")

                default:
                    throw PluginError.runtime("unknown capability \(name)")
                }
            } catch {
                self.resolve(callID, ok: false,
                             value: error.localizedDescription)
            }
        }
    }

    private func has(_ permission: PluginPermission) -> Bool {
        permissions.contains(permission)
    }

    private func resolve(_ callID: String, ok: Bool, value: String) {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        queue.async { [weak self] in
            guard let self else { return }
            self.context.evaluateScript("__amore_resolve('\(callID)', \(ok ? "true" : "false"), '\(escaped)')")
        }
    }

    static func host(of urlString: String) -> String? {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return nil }
        return url.host?.lowercased()
    }
}
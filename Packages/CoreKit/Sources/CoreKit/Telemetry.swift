import Foundation
import OSLog

#if canImport(MetricKit) && os(iOS)
import MetricKit

/// Receives MetricKit payloads (crashes, hangs, launch time, memory) and keeps a
/// compact JSON history in Application Support so the diagnostics screen can
/// show them without a backend.
public final class TelemetryReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = TelemetryReporter()

    private let directory: URL
    private let logger = AmoreLogger(category: "Telemetry")
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = (directory ?? base).appendingPathComponent("Diagnostics", isDirectory: true)
        super.init()
    }

    public func start() {
        MXMetricManager.shared.add(self)
        logger.info("metrickit subscriber attached")
    }

    public func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: MXMetricManagerSubscriber

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: "metrics")
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: "diagnostics")
        }
    }

    private func store(_ data: Data, kind: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(kind)-\(Int(Date().timeIntervalSince1970)).json"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            pruneOldFiles()
        } catch {
            logger.error("could not persist \(kind) payload")
        }
    }

    /// Keeps the newest 20 payloads; diagnostics history must not grow forever.
    private func pruneOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)
        else { return }
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in sorted.dropFirst(20) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func exportAll() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
#else

/// Non-iOS platforms have no MetricKit; the app still builds against this stub.
public final class TelemetryReporter: @unchecked Sendable {
    public static let shared = TelemetryReporter()
    public init(directory: URL? = nil) {}
    public func start() {}
    public func stop() {}
    public func exportAll() -> [URL] { [] }
}
#endif
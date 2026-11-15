import Foundation
import MarketplaceKit
import Observation
import PluginKit

/// Drives the marketplace screen. Owns no SwiftUI types, so it can be tested by
/// swapping in stub services.
@MainActor
@Observable
public final class MarketplaceStore {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case loaded([RegistryEntry])
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var installingID: String?
    public private(set) var installProgress: Double = 0
    public private(set) var banner: String?
    public private(set) var rateLimitedUntil: Date?
    public var searchText: String = ""

    private let client: RegistryClient
    private let pipeline: InstallPipeline
    private let permissionsForEntry: @Sendable (RegistryEntry) async throws -> [PluginPermission]

    public init(client: RegistryClient,
                pipeline: InstallPipeline,
                permissionsForEntry: @escaping @Sendable (RegistryEntry) async throws -> [PluginPermission]) {
        self.client = client
        self.pipeline = pipeline
        self.permissionsForEntry = permissionsForEntry
    }

    // MARK: Listing

    public func load() async {
        phase = .loading
        do {
            var entries = try await client.fetchIndex()
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let query = searchText.lowercased()
                entries = entries.filter {
                    $0.name.lowercased().contains(query) ||
                    $0.id.lowercased().contains(query) ||
                    $0.tags.contains { $0.lowercased().contains(query) }
                }
            }
            // Verified entries first, then by stars — the badge is the trust signal.
            entries.sort {
                if $0.verified != $1.verified { return $0.verified }
                return ($0.stars ?? 0) > ($1.stars ?? 0)
            }
            phase = .loaded(entries)
        } catch let error as MarketplaceError {
            if case .rateLimited(let reset) = error { rateLimitedUntil = reset }
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Install

    public func install(_ entry: RegistryEntry, signature: Data) async {
        guard installingID == nil else { return }
        installingID = entry.id
        installProgress = 0
        banner = nil
        do {
            let approved = try await permissionsForEntry(entry)
            installProgress = 0.35
            let record = try await pipeline.install(entry: entry,
                                                    signature: signature,
                                                    approvedPermissions: approved)
            installProgress = 1
            banner = "\(record.id) \(record.version) 已安装"
        } catch PluginError.permissionDenied(let permission) {
            banner = "插件缺少权限：\(permission)"
        } catch {
            banner = error.localizedDescription
        }
        installingID = nil
    }

    public func dismissBanner() { banner = nil }
}
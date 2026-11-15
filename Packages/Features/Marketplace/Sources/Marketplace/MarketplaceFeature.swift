import DesignSystem
import PluginKit
import SwiftUI

/// Marketplace list. Every row comes from `RegistryClient`; nothing here is
/// placeholder content — an empty state means the index really was empty.
public struct MarketplaceFeatureEntry: View {
    @State private var store: MarketplaceStore?
    @State private var pending: RegistryEntry?
    @State private var search = ""

    private let makeStore: @MainActor () -> MarketplaceStore?

    public init(makeStore: @escaping @MainActor () -> MarketplaceStore) {
        self.makeStore = makeStore
    }

    /// Used before the app wires real services (RootView currently instantiates
    /// this). Renders an honest "not configured" state instead of a fake list.
    public init() {
        self.makeStore = { nil }
    }

    public var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ContentUnavailableView(
                    "市场服务未接入",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("需要注入 RegistryClient 与 InstallPipeline 后才会加载真实索引。")
                )
            }
        }
        .task {
            guard store == nil, let created = makeStore() else { return }
            store = created
            await created.load()
        }
        .navigationTitle("插件市场")
        .searchable(text: $search, prompt: "搜索名称、id 或标签")
        .onSubmit(of: .search) {
            Task {
                guard let store else { return }
                store.searchText = search
                await store.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ store: MarketplaceStore) -> some View {
        List {
            if let banner = store.banner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let reset = store.rateLimitedUntil {
                Section {
                    Label("GitHub 额度已用完，稍后再试（重置：\(reset.formatted(date: .omitted, time: .shortened))）",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }
            switch store.phase {
            case .idle, .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .failed(let message):
                Section {
                    ContentUnavailableView("无法加载市场", systemImage: "wifi.exclamationmark",
                                           description: Text(message))
                }
            case .loaded(let entries):
                if entries.isEmpty {
                    Section {
                        ContentUnavailableView("没有匹配的插件", systemImage: "magnifyingglass")
                    }
                } else {
                    Section {
                        ForEach(entries) { entry in
                            row(entry, store: store)
                        }
                    } footer: {
                        Text("「已审核」表示由官方索引签名；社区条目安装前请自行确认权限。")
                    }
                }
            }
        }
        .refreshable { await store.load() }
        .sheet(item: $pending) { entry in
            PermissionSheet(entry: entry) {
                pending = nil
            }
        }
    }

    private func row(_ entry: RegistryEntry, store: MarketplaceStore) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.medium))
                    badge(entry.verified)
                }
                Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(entry.latestVersion).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if store.installingID == entry.id {
                    ProgressView(value: store.installProgress)
                        .frame(width: 64)
                } else {
                    Button("安装") { pending = entry }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func badge(_ verified: Bool) -> some View {
        if verified {
            Label("已审核", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.green)
        } else {
            Label("未审核", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

/// Consent sheet: every permission is explained in plain Chinese before the
/// install proceeds. Signature bytes arrive from the registry entry in a later
/// phase; here the sheet only gates the user's decision.
struct PermissionSheet: View {
    let entry: RegistryEntry
    let onDismiss: () -> Void
    @State private var accepted = false

    private var permissions: [PluginPermission] {
        (try? PluginPermissionCatalog.resolve(entry.tags)) ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section("插件") {
                    LabeledContent("名称", value: entry.name)
                    LabeledContent("id", value: entry.id)
                    LabeledContent("版本", value: entry.latestVersion)
                    if !entry.verified {
                        Label("社区条目未经官方签名", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section("这个插件将获得") {
                    if permissions.isEmpty {
                        Text("不请求任何权限").foregroundStyle(.secondary)
                    } else {
                        ForEach(permissions, id: \.rawValue) { permission in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.rawValue).font(.footnote.monospaced())
                                Text(permission.localizedExplanation)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Toggle("我了解并同意以上权限", isOn: $accepted)
                } footer: {
                    Text("当前版本只完成权限确认；签名资产（signature.sig）下载与安装会在下一步接入，按钮不会假装已经安装。")
                }
            }
            .navigationTitle("安装确认")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { onDismiss() }
                        .disabled(!accepted)
                }
            }
        }
    }
}
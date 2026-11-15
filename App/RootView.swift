import SwiftUI
import CoreKit
import Chat
import Marketplace
import Memory
import PluginManager
import Settings

/// Root layout: tabs on iPhone, split view on iPad/Mac. Both share the same
/// `Router`, so a deep link lands in the right place on either layout.
@MainActor
struct RootView: View {
    @State private var router = Router()
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        Group {
            #if os(macOS)
            splitLayout
            #else
            GeometryReader { proxy in
                if proxy.size.width >= 720 {
                    splitLayout
                } else {
                    tabLayout
                }
            }
            #endif
        }
        .environment(router)
        .environment(\.dependencies, dependencies)
        .onOpenURL { url in
            if !router.handle(url) {
                dependencies.logger("DeepLink").warning("unhandled url \(url.scheme ?? "?")")
            }
        }
        .tint(.accentColor)
    }

    // MARK: - iPhone

    private var tabLayout: some View {
        TabView(selection: Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: Binding(
                    get: { router.path(for: tab) },
                    set: { router.setPath($0, for: tab) }
                )) {
                    tabRoot(tab)
                        .navigationDestination(for: Route.self) { route in
                            destination(route)
                        }
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }

    // MARK: - iPad / Mac

    private var splitLayout: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: Binding<AppTab?>(
                get: { router.selectedTab },
                set: { if let value = $0 { router.selectedTab = value } }
            )) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .tag(tab)
            }
            .navigationTitle("Amore")
        } detail: {
            NavigationStack(path: Binding(
                get: { router.path(for: router.selectedTab) },
                set: { router.setPath($0, for: router.selectedTab) }
            )) {
                tabRoot(router.selectedTab)
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                    }
            }
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        switch tab {
        case .chat:        ChatFeatureEntry()
        case .agents:      AgentsRootView()
        case .tasks:       TasksRootView()
        case .memory:      MemoryFeatureEntry()
        case .profile:     SettingsFeatureEntry()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .chat:
            ChatFeatureEntry()
        case .agents:
            AgentsRootView()
        case .tasks:
            TasksRootView()
        case .memory:
            MemoryFeatureEntry()
        case .profile:
            SettingsFeatureEntry()
        case .marketplace:
            MarketplaceFeatureEntry()
        case .settings:
            SettingsFeatureEntry()
        case .pluginDetail(let id):
            StagePlaceholderView(title: "Plugin detail", detail: id, stage: "P5/P6")
        case .pluginInstall(let id):
            StagePlaceholderView(title: "Install plugin", detail: id, stage: "P6")
        }
    }
}

/// Honest placeholder: shows the stage that will implement the screen instead
/// of imitating a working feature.
struct StagePlaceholderView: View {
    let title: String
    let detail: String?
    let stage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "hammer")
        } description: {
            VStack(spacing: 6) {
                if let detail {
                    Text(detail).font(.footnote.monospaced())
                }
                Text("Scheduled for \(stage)")
            }
        }
    }
}

struct AgentsRootView: View {
    var body: some View {
        StagePlaceholderView(title: "Agents", detail: nil, stage: "P3/P7")
            .navigationTitle("Agents")
    }
}

struct TasksRootView: View {
    var body: some View {
        StagePlaceholderView(title: "Tasks", detail: nil, stage: "P3/P8")
            .navigationTitle("Tasks")
    }
}
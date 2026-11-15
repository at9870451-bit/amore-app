import SwiftUI
import CoreKit

@main
struct AmoreApp: App {
    /// Single composition root for the process. Feature stores receive their
    /// dependencies from here through the environment.
    private let dependencies = DependencyContainer.live

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.dependencies, dependencies)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
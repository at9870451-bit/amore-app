import SwiftUI

/// Stage placeholder: the PluginManager feature lands in a later phase.
public struct PluginManagerFeatureEntry: View {
    public init() {}
    public var body: some View {
        ContentUnavailableView("PluginManager", systemImage: "hammer", description: Text("Not implemented yet"))
    }
}

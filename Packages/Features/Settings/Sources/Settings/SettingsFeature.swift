import SwiftUI

/// Stage placeholder: the Settings feature lands in a later phase.
public struct SettingsFeatureEntry: View {
    public init() {}
    public var body: some View {
        ContentUnavailableView("Settings", systemImage: "hammer", description: Text("Not implemented yet"))
    }
}

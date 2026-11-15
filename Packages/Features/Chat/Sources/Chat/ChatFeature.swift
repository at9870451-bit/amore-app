import SwiftUI

/// Stage placeholder: the Chat feature lands in a later phase.
public struct ChatFeatureEntry: View {
    public init() {}
    public var body: some View {
        ContentUnavailableView("Chat", systemImage: "hammer", description: Text("Not implemented yet"))
    }
}
